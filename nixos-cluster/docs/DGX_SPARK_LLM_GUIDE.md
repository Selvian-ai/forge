# Running LLMs Optimally on NVIDIA DGX Spark

> Based on benchmarks from [ggml-org/llama.cpp#16578](https://github.com/ggml-org/llama.cpp/discussions/16578)
> and [r/LocalLLaMA comparison](https://www.reddit.com/r/LocalLLaMA/comments/1o7k7zz/dgx_spark_compiled_llamacpp_benchmarks_compared/)

## TL;DR

**Stop using Ollama in Docker.** Use **Ray Serve + vLLM**.

Our automated pipelines (not humans) send requests to the Spark. They run
sequentially today, but the hardware can handle parallel workloads. Ray Serve
with vLLM unlocks this: continuous batching keeps the GPU saturated across
concurrent requests, and a single OpenAI-compatible API serves LLMs, vision
models, embeddings, and audio transcription simultaneously.

llama.cpp is documented below as a fallback for simple single-model use cases,
but Ray Serve is the primary recommended stack for our system.

The DGX Spark (GB10) has a Blackwell GPU with 128GB unified memory and ~273 GB/s
bandwidth. It excels at prompt processing (~2-4x faster than M4 Max) but is slower
at token generation (~0.7x) due to lower memory bandwidth. To get the most out of
it, you need proper CUDA builds, `--no-mmap`, and kernel-level tuning.

---

## Why Ollama + Docker is Slow

1. **Everything is sequential.** Ollama and llama.cpp (with `-np 1`) process
   one request at a time. When our pipelines send 10 requests, the GPU sits
   idle between each one. vLLM's continuous batching processes them
   concurrently -- the GPU stays at 85-92% utilization instead of spiking
   and idling repeatedly.
2. **No multi-modal support.** Ollama can't serve embeddings, vision, and
   text from one endpoint. Our pipelines need to hit different services
   for different tasks, adding complexity and preventing co-scheduling.
3. **Ollama wraps llama.cpp** but adds 10-30% overhead (HTTP server, model
   management, Go runtime).
4. **Default Ollama settings** are not tuned for DGX Spark. It doesn't use
   flash attention by default, doesn't disable mmap, and uses conservative
   batch sizes.
5. **Model format matters.** Ollama uses its own model registry. Native
   HuggingFace weights with FP8/NVFP4 quantization give better results
   on Blackwell hardware.

---

## Hardware Overview

| Spec                | DGX Spark (GB10)                        |
| ------------------- | --------------------------------------- |
| GPU                 | Blackwell, 5th-gen Tensor Cores         |
| Compute Capability  | sm_121 (12.1)                           |
| Memory              | 128 GB LPDDR5x unified                  |
| Memory Bandwidth    | ~273 GB/s                               |
| Compute             | 1 PFLOP (sparse FP4)                    |
| CPU                 | 20-core ARM (10x Cortex-X925 + 10x A725) |
| Storage             | NVMe M.2                                |
| Networking          | ConnectX-7 200GbE                       |
| Power               | 240W                                    |

**Key insight:** The Spark has ~2x less memory bandwidth than an M4 Max (273 vs 546 GB/s),
so token generation (which is memory-bandwidth bound) is slower. But the Blackwell GPU
has vastly superior compute, so prompt processing (compute-bound) is 2-5x faster.

---

## Step 1: Build llama.cpp from Source with CUDA

Do NOT use pre-built binaries or Ollama. Build directly on the Spark.

```bash
# Clone llama.cpp
git clone https://github.com/ggml-org/llama.cpp.git
cd llama.cpp

# Build with CUDA support
cmake -B build-cuda -DGGML_CUDA=ON
cmake --build build-cuda -j

# Optionally install system-wide
sudo cp build-cuda/bin/llama-* /usr/local/bin/
```

### NixOS Alternative

If running NixOS on the Spark, add to your configuration:

```nix
# In your configuration.nix or common.nix
environment.systemPackages = with pkgs; [
  # ... existing packages ...
  cmake
  gcc
  gnumake
  cudatoolkit
  cudaPackages.cudnn
];
```

Then build llama.cpp in a nix-shell or FHS environment:

```bash
nix-shell -p cmake gcc gnumake cudatoolkit --run "
  cd /path/to/llama.cpp
  cmake -B build-cuda -DGGML_CUDA=ON
  cmake --build build-cuda -j
"
```

---

## Step 2: Kernel and System Tuning

These optimizations are **critical** for DGX Spark performance. Without them,
you may see 30-50% less throughput.

### 2a. Disable mmap (Most Important)

mmap performance on DGX Spark is terrible across all tested kernels.
**Always use `--no-mmap` (or `-mmp 0`).**

| Loading Method | gpt-oss-120b Load Time |
| -------------- | ---------------------- |
| With mmap      | ~1min 30s - 2min       |
| Without mmap   | ~15-27s                |

### 2b. Increase NVMe Read-Ahead Buffer

```bash
# Dramatically improves model loading speed
sudo bash -c "echo 8192 > /sys/block/nvme0n1/queue/read_ahead_kb"
```

On kernel 6.17+, this improves both mmap and non-mmap loading.
On kernel 6.14, it primarily helps non-mmap loading.

To persist across reboots (NixOS):

```nix
# In your NixOS configuration
boot.kernel.sysctl = {};  # sysctl doesn't cover block devices

# Use a systemd tmpfiles rule or oneshot service instead:
systemd.services.nvme-readahead = {
  description = "Set NVMe read-ahead for LLM loading";
  wantedBy = [ "multi-user.target" ];
  serviceConfig = {
    Type = "oneshot";
    ExecStart = "${pkgs.bash}/bin/bash -c 'echo 8192 > /sys/block/nvme0n1/queue/read_ahead_kb'";
    RemainAfterExit = true;
  };
};
```

### 2c. Kernel Version

Performance varies significantly by kernel version:

| Kernel | Model Load (no-mmap) | Performance Notes         |
| ------ | -------------------- | ------------------------- |
| 6.11   | ~68s                 | Baseline, slow            |
| 6.14   | ~27s                 | Major improvement         |
| 6.17+  | ~15-22s              | Best, enables NO_PAGE_MAPCOUNT |

If running DGX OS, update to latest. If running custom NixOS, target kernel 6.17+.

### 2d. CUDA Spin Scheduling

The DGX Spark benefits from CUDA spin scheduling (already enabled in recent
llama.cpp builds for compute capability 12.1). This trades CPU usage for lower
GPU launch latency.

### 2e. Disable CPU Idle States (For Multi-Node / Low-Latency)

If running a multi-Spark cluster with RPC, disabling CPU idle states
dramatically reduces network latency:

```bash
# Reduces ping from ~1ms to ~0.02ms between nodes
sudo cpupower idle-set -D 0
```

---

## Step 3: Running Models

### Interactive Chat (llama-server)

```bash
# Recommended: gpt-oss-120b (fits entirely in 128GB)
llama-server \
  -hf ggml-org/gpt-oss-120b-GGUF \
  --ctx-size 131072 \
  -np 1 \
  --jinja \
  -ub 2048 \
  -b 2048 \
  -ngl 99 \
  -fa \
  --no-mmap \
  --port 8080

# Access at http://localhost:8080
```

**Important flags explained:**

| Flag          | Purpose                                              |
| ------------- | ---------------------------------------------------- |
| `-ngl 99`     | Offload all layers to GPU                            |
| `-fa`         | Enable flash attention (critical for performance)    |
| `--no-mmap`   | Disable memory mapping (critical on Spark)           |
| `-ub 2048`    | Micro-batch size for prompt processing               |
| `-b 2048`     | Batch size                                           |
| `-np 1`       | Single slot (avoids unified KV cache slowdown bug)   |
| `--ctx-size`  | Context window size in tokens                        |

### Benchmarking

```bash
# Sequential benchmark (single request)
llama-bench \
  -m model.gguf \
  -fa 1 \
  -d 0,4096,8192,16384,32768 \
  -p 2048 \
  -n 32 \
  -ub 2048 \
  -mmp 0

# Parallel benchmark (batched requests)
llama-batched-bench \
  -m model.gguf \
  -fa 1 \
  -c 300000 \
  -ub 2048 \
  -npp 4096,8192 \
  -ntg 32 \
  -npl 1,2,4,8,16,32 \
  --no-mmap
```

---

## Step 4: Model Selection

### Models That Fit in 128GB (Single Spark)

| Model                         | Size     | Format    | Use Case               |
| ----------------------------- | -------- | --------- | ---------------------- |
| gpt-oss-120b MXFP4            | 59 GiB   | MXFP4     | General reasoning, code |
| gpt-oss-20b MXFP4             | 11.3 GiB | MXFP4     | Fast general purpose   |
| Qwen3-Coder-30B-A3B Q8_0     | 30.3 GiB | Q8_0      | Code generation        |
| GLM-4.5-Air Q4_K             | 67.9 GiB | Q4_K      | General purpose        |
| MiniMax-M2 Q3_K_XL           | 94.5 GiB | Q3_K_XL   | 230B MoE, 64K context  |
| Qwen2.5-Coder-7B Q8_0        | 7.5 GiB  | Q8_0      | Lightweight coding     |

### Expected Performance (Single Spark, Latest llama.cpp)

| Model                    | Prompt (pp2048) | Generation (tg32) |
| ------------------------ | --------------- | ------------------ |
| gpt-oss-20b MXFP4       | ~3,600 t/s      | ~80 t/s            |
| gpt-oss-120b MXFP4      | ~2,400 t/s      | ~58 t/s            |
| Qwen3-Coder-30B Q8_0    | ~2,900 t/s      | ~60 t/s            |
| Qwen2.5-Coder-7B Q8_0   | ~2,270 t/s      | ~29 t/s            |
| GLM-4.5-Air Q4_K        | ~840 t/s        | ~23 t/s            |
| MiniMax-M2 Q3_K_XL      | ~890 t/s        | ~30 t/s            |

### Downloading Models

```bash
# llama.cpp can download directly from HuggingFace
llama-server -hf ggml-org/gpt-oss-120b-GGUF ...

# Or download manually
huggingface-cli download ggml-org/gpt-oss-120b-GGUF --local-dir ./models/
```

---

## Step 5: Serving for Applications (OpenAI-Compatible API)

llama-server provides an OpenAI-compatible API out of the box:

```bash
llama-server \
  -hf ggml-org/gpt-oss-120b-GGUF \
  --ctx-size 1048576 \
  -np 1 \
  --jinja \
  -ub 2048 \
  -b 2048 \
  -ngl 99 \
  -fa \
  --no-mmap \
  --temp 1.0 \
  --top-p 1.0 \
  --top-k 0 \
  --min-p 0.01 \
  --port 8080 \
  --host 0.0.0.0
```

Then use it from any OpenAI client:

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://spark-ip:8080/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="gpt-oss-120b",
    messages=[{"role": "user", "content": "Hello!"}]
)
```

---

## Step 6: systemd Service (Production)

Create a systemd service for persistent LLM serving:

```nix
# NixOS service definition
systemd.services.llama-server = {
  description = "llama.cpp inference server";
  after = [ "network.target" "nvidia-persistenced.service" ];
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "simple";
    ExecStart = ''
      /usr/local/bin/llama-server \
        -m /models/gpt-oss-120b-mxfp4.gguf \
        --ctx-size 131072 \
        -np 1 \
        --jinja \
        -ub 2048 \
        -b 2048 \
        -ngl 99 \
        -fa \
        --no-mmap \
        --port 8080 \
        --host 0.0.0.0
    '';
    Restart = "on-failure";
    RestartSec = 10;
    # Increase file descriptor limits for large models
    LimitNOFILE = 65536;
  };
};
```

Or as a shell script managed by systemd:

```bash
#!/usr/bin/env bash
# /opt/llm/start-server.sh

# System tuning
echo 8192 > /sys/block/nvme0n1/queue/read_ahead_kb

exec /usr/local/bin/llama-server \
  -m /models/gpt-oss-120b-mxfp4.gguf \
  --ctx-size 131072 \
  -np 1 \
  --jinja \
  -ub 2048 \
  -b 2048 \
  -ngl 99 \
  -fa \
  --no-mmap \
  --port 8080 \
  --host 0.0.0.0
```

---

## Multi-Node (Dual Spark) Setup

If you have two DGX Sparks connected via 200GbE:

### RPC Backend

```bash
# On the remote Spark (worker):
llama-rpc-server --host 0.0.0.0 --port 15001

# On the primary Spark (controller):
llama-server \
  -m model.gguf \
  --rpc remote-spark-ip:15001 \
  -fa \
  --no-mmap \
  -ngl 99 \
  --port 8080
```

### Multi-Node Performance Tips

1. **Use InfiniBand/RoCE** over Ethernet when possible (ConnectX-7 supports both).
   NCCL over IB gives ~76 t/s vs ~56 t/s over Ethernet for Qwen3-30B.
2. **Disable CPU idle states** on both nodes: `sudo cpupower idle-set -D 0`
   This reduces network latency from ~1ms to ~0.02ms.
3. **Models that benefit from dual-Spark:** MiniMax-M2 Q4_K_XL (123 GiB),
   Qwen3-VL-235B Q4_K_XL (125 GiB), or running larger quantizations of
   models that otherwise need aggressive quantization.

### Dual-Spark Benchmark (gpt-oss-120b, with idle-state tuning)

| Test              | Single Spark | Dual Spark (RPC) |
| ----------------- | ------------ | ---------------- |
| pp2048            | ~2,400 t/s   | ~1,765 t/s       |
| tg32              | ~58 t/s      | ~55 t/s          |

Note: Dual Spark is only beneficial for models too large for a single node.
For models that fit in 128GB, a single Spark is faster.

---

## Ray Serve: Multi-Modal Inference Platform

> [Ray Serve docs](https://docs.ray.io/en/latest/serve/llm/serving-llms.html) |
> [vLLM compatibility guide](https://docs.ray.io/en/latest/serve/llm/user-guides/vllm-compatibility.html) |
> [NVIDIA DGX Spark vLLM playbook](https://build.nvidia.com/spark/vllm) |
> [vllm-dgx-spark repo](https://github.com/mark-ramsey-ri/vllm-dgx-spark)

Ray Serve wraps vLLM and provides a unified multi-model, multi-modal serving
platform with autoscaling and a single OpenAI-compatible API. This is the
recommended stack for our automated pipelines.

### Why Ray Serve for Automated Pipelines

Our system sends requests programmatically -- not a human typing one prompt
at a time. This fundamentally changes what matters:

**The sequential bottleneck today:**
```
Pipeline step 1: embed document    → GPU busy → GPU idle
Pipeline step 2: LLM analyze       → GPU busy → GPU idle
Pipeline step 3: vision OCR        → GPU busy → GPU idle
Pipeline step 4: LLM summarize     → GPU busy → GPU idle
Total: 4x (compute + idle overhead)
```

**With Ray Serve + vLLM (parallel):**
```
Pipeline fires all 4 concurrently  → GPU stays saturated
vLLM continuous batching merges     → PagedAttention shares KV cache
Requests complete as they finish    → no waiting in line
Total: ~1x compute (GPU never idles)
```

vLLM's continuous batching doesn't wait for a batch to fill -- new requests
join the GPU immediately at iteration-level granularity. PagedAttention
allocates KV cache memory on-demand (like virtual memory pages), eliminating
the 60-80% memory waste of pre-allocated contiguous buffers. This means:

- **16 concurrent requests**: 11-23% faster per-request than sequential
- **Total throughput**: up to 35x higher than single-slot llama.cpp
- **Stable latency**: P99 TTFT stays under 100ms even under load (llama.cpp
  TTFT grows exponentially with queue depth)

### When llama.cpp Still Makes Sense

| Scenario                          | Best Choice     | Why                                    |
| --------------------------------- | --------------- | -------------------------------------- |
| Quick ad-hoc testing              | llama.cpp       | No Docker, instant setup               |
| Single sequential request         | llama.cpp       | 4-6% faster per-request                |
| Model not supported by vLLM       | llama.cpp       | Broader GGUF format support             |
| Everything else (our use case)    | Ray + vLLM      | Parallelism, multi-modal, autoscaling   |

### DGX Spark Compatibility Note

The Spark uses an **ARM64 CPU** and requires **CUDA 13.0+** for the Blackwell
GPU. Most pip packages ship x86/CUDA 12 wheels. Use NVIDIA's container image:

```bash
docker pull nvcr.io/nvidia/vllm:25.11-py3
```

This image bundles vLLM, Ray, CUDA 13, and ARM64 support. It's the only
reliable way to run vLLM on Spark without building everything from source.

### Single-Node Setup

#### Quick Start with the Community Script

The [vllm-dgx-spark](https://github.com/mark-ramsey-ri/vllm-dgx-spark) repo
provides single-command deployment with 13 model presets:

```bash
git clone https://github.com/mark-ramsey-ri/vllm-dgx-spark.git
cd vllm-dgx-spark

# Single-node, auto-detects GPU
./deploy.sh --model gpt-oss-120b
```

#### Manual Docker Setup

```bash
export VLLM_IMAGE=nvcr.io/nvidia/vllm:25.11-py3
export HF_CACHE=$HOME/.cache/huggingface

# Run vLLM directly (single model)
docker run --rm --gpus all \
  -v $HF_CACHE:/root/.cache/huggingface \
  -p 8000:8000 \
  $VLLM_IMAGE \
  vllm serve ggml-org/gpt-oss-120b-GGUF \
    --host 0.0.0.0 \
    --port 8000 \
    --gpu-memory-utilization 0.9 \
    --max-model-len 131072
```

### Multi-Modal Ray Serve Configuration

This is the real power of Ray -- serving multiple model types from one cluster.

#### Deploy Script: `ray_serve_multimodal.py`

```python
from ray import serve
from ray.serve.llm import LLMConfig, LLMServingArgs, build_openai_app

# --- Text LLM (reasoning / code) ---
reasoning_config = LLMConfig(
    model_loading_config=dict(
        model_id="gpt-oss-120b",
        model_source="ggml-org/gpt-oss-120b-GGUF",
    ),
    engine_kwargs=dict(
        max_model_len=131072,
        gpu_memory_utilization=0.7,  # Leave room for other models
    ),
    deployment_config=dict(
        autoscaling_config=dict(min_replicas=1, max_replicas=1),
    ),
)

# --- Vision LLM (image + text understanding) ---
vision_config = LLMConfig(
    model_loading_config=dict(
        model_id="qwen-vl",
        model_source="Qwen/Qwen2.5-VL-7B-Instruct",
    ),
    engine_kwargs=dict(
        max_model_len=8192,
        tensor_parallel_size=1,
    ),
    deployment_config=dict(
        autoscaling_config=dict(min_replicas=0, max_replicas=1),
    ),
)

# --- Embeddings (for RAG pipelines) ---
embedding_config = LLMConfig(
    model_loading_config=dict(
        model_id="embed-model",
        model_source="Qwen/Qwen2.5-0.5B-Instruct",
    ),
    engine_kwargs=dict(
        task="embed",
    ),
    deployment_config=dict(
        autoscaling_config=dict(min_replicas=1, max_replicas=2),
    ),
)

# --- Audio Transcription (speech-to-text) ---
transcription_config = LLMConfig(
    model_loading_config=dict(
        model_id="voxtral-mini",
        model_source="mistralai/Voxtral-Mini-3B-2507",
    ),
    engine_kwargs=dict(
        tokenizer_mode="mistral",
        config_format="mistral",
        load_format="mistral",
    ),
    deployment_config=dict(
        autoscaling_config=dict(min_replicas=0, max_replicas=1),
    ),
)

# Build unified app -- all models behind one API
app = build_openai_app(LLMServingArgs(
    llm_configs=[
        reasoning_config,
        vision_config,
        embedding_config,
        transcription_config,
    ]
))

serve.run(app, blocking=True)
```

#### Running the Multi-Modal Server

```bash
docker run --rm --gpus all \
  -v $HOME/.cache/huggingface:/root/.cache/huggingface \
  -v $(pwd)/ray_serve_multimodal.py:/app/serve.py \
  -p 8000:8000 \
  $VLLM_IMAGE \
  python /app/serve.py
```

### Using the Multi-Modal API

All endpoints are OpenAI-compatible. Select the model via the `model` field.

#### Text Chat

```python
from openai import OpenAI
client = OpenAI(base_url="http://spark-ip:8000/v1", api_key="not-needed")

response = client.chat.completions.create(
    model="gpt-oss-120b",
    messages=[{"role": "user", "content": "Explain PagedAttention"}],
)
```

#### Vision (Image + Text)

```python
response = client.chat.completions.create(
    model="qwen-vl",
    messages=[{
        "role": "user",
        "content": [
            {"type": "text", "text": "What's in this image?"},
            {"type": "image_url", "image_url": {"url": "https://example.com/chart.png"}},
        ],
    }],
)
```

#### Embeddings (for RAG)

```python
response = client.embeddings.create(
    model="embed-model",
    input=["Document chunk to embed", "Another chunk"],
)
vectors = [d.embedding for d in response.data]
```

#### Audio Transcription

```python
with open("meeting.wav", "rb") as f:
    response = client.audio.transcriptions.create(
        model="voxtral-mini",
        file=f,
        language="en",
    )
print(response.text)
```

#### Structured JSON Output

```python
from pydantic import BaseModel
from typing import List

class Analysis(BaseModel):
    summary: str
    key_points: List[str]
    sentiment: str

response = client.chat.completions.create(
    model="gpt-oss-120b",
    response_format={
        "type": "json_schema",
        "json_schema": Analysis.model_json_schema(),
    },
    messages=[{"role": "user", "content": "Analyze this earnings report..."}],
)
```

### Parallel Pipeline Pattern

The whole point of Ray Serve is that our automated system can fire requests
concurrently instead of waiting for each one to complete. Here's how to
structure pipeline code to take advantage of this.

#### Before: Sequential (current Ollama approach)

```python
# Each call blocks until complete. GPU idles between calls.
embedding = client.embeddings.create(model="embed-model", input=[chunk])
analysis = client.chat.completions.create(model="gpt-oss-120b", messages=[...])
vision_result = client.chat.completions.create(model="qwen-vl", messages=[...])
summary = client.chat.completions.create(model="gpt-oss-120b", messages=[...])
# Total wall time: sum of all four calls
```

#### After: Parallel with asyncio

```python
import asyncio
from openai import AsyncOpenAI

client = AsyncOpenAI(base_url="http://spark-ip:8000/v1", api_key="not-needed")

async def process_document(doc: str, image_url: str):
    # Fire all independent requests concurrently
    embedding_task = client.embeddings.create(
        model="embed-model", input=[doc]
    )
    analysis_task = client.chat.completions.create(
        model="gpt-oss-120b",
        messages=[{"role": "user", "content": f"Analyze: {doc}"}],
    )
    vision_task = client.chat.completions.create(
        model="qwen-vl",
        messages=[{
            "role": "user",
            "content": [
                {"type": "text", "text": "Extract text from this image"},
                {"type": "image_url", "image_url": {"url": image_url}},
            ],
        }],
    )

    # All three run concurrently on the GPU via vLLM continuous batching
    embedding, analysis, vision_result = await asyncio.gather(
        embedding_task, analysis_task, vision_task
    )

    # Now use results for a dependent step
    summary = await client.chat.completions.create(
        model="gpt-oss-120b",
        messages=[{
            "role": "user",
            "content": f"Summarize:\nAnalysis: {analysis.choices[0].message.content}\nOCR: {vision_result.choices[0].message.content}",
        }],
    )
    return embedding, analysis, vision_result, summary

# Process multiple documents concurrently too
async def batch_process(documents):
    tasks = [process_document(doc, img) for doc, img in documents]
    return await asyncio.gather(*tasks)
```

#### After: Parallel with concurrent.futures (sync code)

If your pipeline is synchronous, use threads -- the OpenAI client releases
the GIL during HTTP I/O:

```python
from concurrent.futures import ThreadPoolExecutor, as_completed
from openai import OpenAI

client = OpenAI(base_url="http://spark-ip:8000/v1", api_key="not-needed")

def embed(text):
    return client.embeddings.create(model="embed-model", input=[text])

def analyze(text):
    return client.chat.completions.create(
        model="gpt-oss-120b",
        messages=[{"role": "user", "content": f"Analyze: {text}"}],
    )

def ocr_image(image_url):
    return client.chat.completions.create(
        model="qwen-vl",
        messages=[{"role": "user", "content": [
            {"type": "text", "text": "Extract text"},
            {"type": "image_url", "image_url": {"url": image_url}},
        ]}],
    )

# Fire all three concurrently
with ThreadPoolExecutor(max_workers=8) as pool:
    futures = {
        pool.submit(embed, doc_text): "embedding",
        pool.submit(analyze, doc_text): "analysis",
        pool.submit(ocr_image, image_url): "vision",
    }
    results = {}
    for future in as_completed(futures):
        results[futures[future]] = future.result()

# GPU processed all three with continuous batching -- no idle time
```

#### Throughput Impact

| Pattern                         | GPU Utilization | Relative Throughput |
| ------------------------------- | --------------- | ------------------- |
| Sequential (Ollama / -np 1)     | ~15-25%         | 1x (baseline)       |
| 4 concurrent requests           | ~60-70%         | ~3-4x               |
| 8 concurrent requests           | ~75-85%         | ~5-7x               |
| 16+ concurrent requests         | ~85-92%         | ~8-12x              |

The exact multiplier depends on model size and request mix, but the key
insight is: **our GPU is mostly idle today because we're serializing
requests.** Parallel requests via Ray Serve fix this immediately.

---

### Multi-Node Ray Cluster (Dual Spark)

For models too large for one Spark, or to increase throughput:

```bash
# --- Node 1 (head): identify the InfiniBand interface ---
export MN_IF_NAME=enp1s0f1np1  # check with: ibdev2netdev
export VLLM_HOST_IP=$(ip -4 addr show $MN_IF_NAME | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

# Download cluster script
wget https://raw.githubusercontent.com/vllm-project/vllm/refs/heads/main/examples/online_serving/run_cluster.sh
chmod +x run_cluster.sh

# Start head node
bash run_cluster.sh $VLLM_IMAGE $VLLM_HOST_IP --head $HF_CACHE \
  -e VLLM_HOST_IP=$VLLM_HOST_IP \
  -e UCX_NET_DEVICES=$MN_IF_NAME \
  -e NCCL_SOCKET_IFNAME=$MN_IF_NAME \
  -e GLOO_SOCKET_IFNAME=$MN_IF_NAME \
  -e TP_SOCKET_IFNAME=$MN_IF_NAME \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR=$VLLM_HOST_IP

# --- Node 2 (worker): ---
export MN_IF_NAME=enp1s0f1np1
export VLLM_HOST_IP=$(ip -4 addr show $MN_IF_NAME | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
export HEAD_NODE_IP=<node-1-qsfp-ip>

bash run_cluster.sh $VLLM_IMAGE $VLLM_HOST_IP --worker $HF_CACHE \
  -e VLLM_HOST_IP=$VLLM_HOST_IP \
  -e UCX_NET_DEVICES=$MN_IF_NAME \
  -e NCCL_SOCKET_IFNAME=$MN_IF_NAME \
  -e GLOO_SOCKET_IFNAME=$MN_IF_NAME \
  -e TP_SOCKET_IFNAME=$MN_IF_NAME \
  -e RAY_memory_monitor_refresh_ms=0 \
  -e MASTER_ADDR=$HEAD_NODE_IP
```

Then serve with tensor parallelism across both nodes:

```bash
# On head node, inside the container:
vllm serve <model> \
  --host 0.0.0.0 \
  --port 8000 \
  -tp 2 \
  --distributed-executor-backend ray
```

**Performance tip:** Use InfiniBand/RoCE, not Ethernet. NCCL over IB gives
~76 t/s vs ~56 t/s over Ethernet (36% faster) for the same model. Disable
CPU idle states on both nodes: `sudo cpupower idle-set -D 0`.

### YAML Config (Alternative to Python)

For deployment via `serve run`:

```yaml
# ray_serve_config.yaml
applications:
  - name: multimodal_app
    import_path: ray.serve.llm:build_openai_app
    route_prefix: "/"
    args:
      llm_configs:
        - model_loading_config:
            model_id: gpt-oss-120b
            model_source: ggml-org/gpt-oss-120b-GGUF
          engine_kwargs:
            max_model_len: 131072
            gpu_memory_utilization: 0.7
          deployment_config:
            autoscaling_config:
              min_replicas: 1
              max_replicas: 1
        - model_loading_config:
            model_id: qwen-vl
            model_source: Qwen/Qwen2.5-VL-7B-Instruct
          engine_kwargs:
            max_model_len: 8192
          deployment_config:
            autoscaling_config:
              min_replicas: 0
              max_replicas: 1
        - model_loading_config:
            model_id: embed-model
            model_source: Qwen/Qwen2.5-0.5B-Instruct
          engine_kwargs:
            task: embed
          deployment_config:
            autoscaling_config:
              min_replicas: 1
              max_replicas: 2
```

```bash
serve run ray_serve_config.yaml
```

### Memory Budget Planning (128GB Unified)

When running multiple models on a single Spark, plan your GPU memory budget:

| Model                        | VRAM Needed | Purpose       |
| ---------------------------- | ----------- | ------------- |
| gpt-oss-120b MXFP4          | ~65 GiB     | Reasoning     |
| Qwen2.5-VL-7B               | ~15 GiB     | Vision        |
| Qwen2.5-0.5B (embed)        | ~2 GiB      | Embeddings    |
| Voxtral-Mini-3B              | ~7 GiB      | Transcription |
| KV cache + overhead          | ~30 GiB     | Runtime       |
| **Total**                    | **~119 GiB**| Fits in 128GB |

Use `gpu_memory_utilization` per model and `min_replicas: 0` for
infrequently-used models so Ray can scale them down when idle.

If memory is tight, swap the 120b reasoning model for a smaller one:

| Budget Config       | Reasoning Model    | VRAM Freed | Trade-off         |
| ------------------- | ------------------ | ---------- | ----------------- |
| Comfortable         | gpt-oss-20b MXFP4 | ~50 GiB    | Slightly less capable |
| Tight               | gpt-oss-120b MXFP4| 0          | Full power, less headroom |
| Dual-Spark          | Split across nodes | N/A        | Network latency cost |

---

## Known Issues and Workarounds

### Unified KV Cache Slowdown

Using multiple server slots (`-np > 1`) with the unified KV cache causes
progressive slowdown over time on CUDA. **Workaround: use `-np 1`.**

> "I have consistently noticed that t/s gets cut in half or more after
> several days of keeping the llama-server up" -- [openmarmot](https://github.com/ggml-org/llama.cpp/discussions/16578)

### mmap is Broken

Even on kernel 6.17, mmap is much slower than direct loading. Always use
`--no-mmap` or `-mmp 0`.

### Token Generation vs Prompt Processing

The Spark's ~273 GB/s bandwidth means token generation is inherently slower
than Apple Silicon (M4 Max at ~546 GB/s). This is a hardware limitation.
The Spark's strength is compute-heavy tasks: prompt processing, batched
inference, and large-context workloads.

---

## Quick Reference: Optimal Launch Commands

### Fast Coding Model (Qwen3-Coder-30B)

```bash
llama-server \
  -hf ggml-org/Qwen3-Coder-30B-A3B-Instruct-GGUF \
  --ctx-size 65536 -np 1 --jinja \
  -ub 2048 -b 2048 -ngl 99 -fa --no-mmap \
  --port 8080 --host 0.0.0.0
```

### Powerful Reasoning (gpt-oss-120b)

```bash
llama-server \
  -hf ggml-org/gpt-oss-120b-GGUF \
  --ctx-size 131072 -np 1 --jinja \
  -ub 2048 -b 2048 -ngl 99 -fa --no-mmap \
  --temp 1.0 --top-p 1.0 --top-k 0 --min-p 0.01 \
  --port 8080 --host 0.0.0.0
```

### Lightweight / Low-Latency (gpt-oss-20b)

```bash
llama-server \
  -hf ggml-org/gpt-oss-20b-GGUF \
  --ctx-size 131072 -np 1 --jinja \
  -ub 2048 -b 2048 -ngl 99 -fa --no-mmap \
  --port 8080 --host 0.0.0.0
```

---

## Migration from Ollama

If you're currently using Ollama models, you can:

1. **Find the GGUF equivalent** on HuggingFace (most popular models have
   GGUF versions from ggml-org or unsloth)
2. **Use llama-server's `-hf` flag** to auto-download from HuggingFace
3. **Point your existing applications** at the new endpoint (same
   OpenAI-compatible API, just change the base URL and port)

### Ollama vs llama-server vs Ray Serve

| Feature              | Ollama                | llama-server              | Ray Serve + vLLM            |
| -------------------- | --------------------- | ------------------------- | --------------------------- |
| Chat completions     | `/api/chat`           | `/v1/chat/completions`    | `/v1/chat/completions`      |
| Completions          | `/api/generate`       | `/v1/completions`         | `/v1/completions`           |
| Embeddings           | `/api/embed`          | Not supported             | `/v1/embeddings`            |
| Vision (image+text)  | Some models           | Not supported             | Full multi-modal            |
| Audio transcription  | Not supported         | Not supported             | `/v1/audio/transcriptions`  |
| Structured JSON      | Not supported         | Not supported             | JSON schema enforcement     |
| Multi-model          | Auto-swap (1 at time) | Single model              | Multiple concurrent models  |
| Concurrent users     | Poor under load       | Single slot recommended   | PagedAttention, autoscaling |
| Model management     | Built-in              | Manual (HF download)      | HF auto-download            |
| Jinja templates      | Limited               | Full (`--jinja`)          | Model-native                |
| Flash attention      | Not configurable      | `-fa` flag                | Automatic                   |
| Setup complexity     | Trivial               | Low                       | Medium (Docker required)    |

---

## References

### llama.cpp
- [DGX Spark benchmarks (official)](https://github.com/ggml-org/llama.cpp/blob/master/benches/dgx-spark/dgx-spark.md)
- [Discussion thread with community benchmarks](https://github.com/ggml-org/llama.cpp/discussions/16578)
- [Reddit: DGX Spark vs M4 Max comparison](https://www.reddit.com/r/LocalLLaMA/comments/1o7k7zz/dgx_spark_compiled_llamacpp_benchmarks_compared/)
- [Setting up DGX Spark with ggml](https://github.com/ggml-org/llama.cpp/discussions/16514)

### Ray Serve + vLLM
- [Ray Serve LLM docs](https://docs.ray.io/en/latest/serve/llm/serving-llms.html)
- [Ray Serve vLLM compatibility (vision, audio, embeddings)](https://docs.ray.io/en/latest/serve/llm/user-guides/vllm-compatibility.html)
- [NVIDIA vLLM DGX Spark playbook (single node)](https://build.nvidia.com/spark/vllm)
- [NVIDIA vLLM DGX Spark playbook (dual node)](https://build.nvidia.com/spark/vllm/stacked-sparks)
- [vllm-dgx-spark community repo](https://github.com/mark-ramsey-ri/vllm-dgx-spark)
- [Ray Serve multi-model config API](https://docs.ray.io/en/latest/serve/api/doc/ray.serve.llm.build_openai_app.html)
- [Ollama vs llama.cpp vs vLLM: 2026 Comparison](https://www.decodesfuture.com/articles/llama-cpp-vs-ollama-vs-vllm-local-llm-stack-guide)

### Hardware
- [NVIDIA DGX Spark hardware docs](https://docs.nvidia.com/dgx/dgx-spark/hardware.html)
- [DGX Spark porting/optimization guide](https://docs.nvidia.com/dgx/dgx-spark-porting-guide/optimization.html)
- [graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark) -- Working NixOS flake for DGX Spark

See [roadmap/](../roadmap/) for the implementation plan.
