# Phase 3: Pipeline Integration

**Status:** not started
**Difficulty:** Easy-Moderate (layered -- start easy, add complexity as needed)
**Time estimate:** Layer 1 is 30 min, Layer 2 is 2 hours, Layer 3 is 1-2 days
**Prerequisite:** Layers 1-2 start immediately; Layer 3 requires Phase 2

---

## Why

Our pipelines currently run on macOS and call inference APIs sequentially
over HTTP. The GPU sits idle between calls. We need to:

1. Eliminate unnecessary network round-trips for batch workloads
2. Fire parallel requests so the GPU stays saturated
3. Keep it simple enough that `just cluster-batch` is all you need

## Strategy: Three Layers, Adopt Incrementally

Start with Layer 1 today. Each layer builds on the previous one.

---

## Layer 1: Justfile + SSH (start immediately)

**Setup:** Trivial -- works right now with zero new infrastructure.

Add cluster recipes to the existing justfile:

```just
# --- Cluster execution recipes ---
cluster_host := "vega"
cluster_dir  := "/opt/pipelines"

# Sync code to cluster (excludes data and venv)
cluster-sync:
  rsync -avz --exclude '.venv' --exclude '__pycache__' --exclude 'data' \
    . {{cluster_host}}:{{cluster_dir}}/

# Run a pipeline step on the cluster
cluster-run +cmd: cluster-sync
  ssh {{cluster_host}} "cd {{cluster_dir}} && {{cmd}}"

# Batch-process all pending items on GPU
cluster-batch: cluster-sync
  ssh {{cluster_host}} "cd {{cluster_dir}} && uv run python scripts/batch_pipeline.py --all"

# Check GPU utilization across cluster
cluster-status:
  @echo "=== vega ===" && ssh vega "nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv"
  @echo "=== rigel ===" && ssh rigel "nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv"
  @echo "=== arcturus ===" && ssh arcturus "nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv"
```

**Best for:** quick iteration, one-off jobs, debugging.

**Limitations:** single node only, no retry/fault tolerance, no job queuing,
blocks your terminal (use tmux/nohup to background).

### Steps

```
[ ] 1. Add cluster-* recipes to justfile
[ ] 2. Ensure SSH keys work for all nodes (already set up)
[ ] 3. Create /opt/pipelines on vega (or wherever code will run)
[ ] 4. Test: just cluster-sync && just cluster-run "nvidia-smi"
```

---

## Layer 2: NFS Shared Filesystem (set up once)

**Setup:** Easy -- one-time configuration, eliminates rsync.

Data and results live on a shared mount accessible from both macOS and all
cluster nodes. No more syncing files back and forth.

### NixOS NFS Server (add to vega's configuration.nix)

```nix
services.nfs.server = {
  enable = true;
  exports = ''
    /mnt/shared 10.10.10.0/24(rw,sync,no_subtree_check,no_root_squash)
  '';
};

# Ensure the directory exists
systemd.tmpfiles.rules = [
  "d /mnt/shared 0755 root root -"
  "d /mnt/shared/input 0755 root root -"
  "d /mnt/shared/output 0755 root root -"
  "d /mnt/shared/hf-cache 0755 root root -"
];
```

### NFS Client (other cluster nodes)

```nix
fileSystems."/mnt/shared" = {
  device = "vega:/mnt/shared";
  fsType = "nfs";
  options = [ "x-systemd.automount" "noauto" "x-systemd.idle-timeout=600" ];
};
```

### macOS Client

```bash
# One-time mount
sudo mount -t nfs vega:/mnt/shared /Volumes/cluster-shared

# Or add to /etc/auto_nfs for auto-mount
# (create /etc/auto_master entry if not exists)
```

### Workflow

```
macOS                              Cluster
  |                                  |
  Write to /Volumes/cluster-shared/  --> /mnt/shared/ (NFS)
  |                                  |
  just cluster-batch                 --> reads /mnt/shared/input/
  |                                  --> writes /mnt/shared/output/
  |                                  |
  Read from /Volumes/cluster-shared/ <-- results available immediately
```

### Steps

```
[ ] 1. Add NFS server config to vega's configuration.nix
[ ] 2. nixos-rebuild switch on vega
[ ] 3. Add NFS client config to other cluster nodes
[ ] 4. nixos-rebuild switch on rigel, arcturus, spark
[ ] 5. Mount on macOS: sudo mount -t nfs vega:/mnt/shared /Volumes/cluster-shared
[ ] 6. Test: touch /Volumes/cluster-shared/test && ssh vega "ls /mnt/shared/test"
[ ] 7. Update justfile cluster recipes to use /mnt/shared paths
```

---

## Layer 3: Parallel API Calls + Ray Jobs (after Phase 2)

Once Ray Serve is running, the pipeline code can fire concurrent requests
and/or submit batch jobs that run entirely on the cluster.

### 3a. Parallel API Calls (refactor pipeline code)

Replace sequential OpenAI calls with concurrent ones. The Ray Serve endpoint
handles batching automatically via vLLM.

**Before (sequential):**
```python
embedding = client.embeddings.create(model="embed-model", input=[chunk])
analysis = client.chat.completions.create(model="gpt-oss-120b", messages=[...])
vision = client.chat.completions.create(model="qwen-vl", messages=[...])
# Total: sum of all three call times
```

**After (parallel with asyncio):**
```python
import asyncio
from openai import AsyncOpenAI

client = AsyncOpenAI(base_url="http://vega:8000/v1", api_key="not-needed")

async def process_document(doc, image_url):
    embedding_task = client.embeddings.create(model="embed-model", input=[doc])
    analysis_task = client.chat.completions.create(
        model="gpt-oss-120b",
        messages=[{"role": "user", "content": f"Analyze: {doc}"}],
    )
    vision_task = client.chat.completions.create(
        model="qwen-vl",
        messages=[{"role": "user", "content": [
            {"type": "text", "text": "Extract text from this image"},
            {"type": "image_url", "image_url": {"url": image_url}},
        ]}],
    )

    # All three run concurrently -- GPU stays saturated
    embedding, analysis, vision = await asyncio.gather(
        embedding_task, analysis_task, vision_task
    )
    return embedding, analysis, vision
```

**After (parallel with threads for sync code):**
```python
from concurrent.futures import ThreadPoolExecutor, as_completed
from openai import OpenAI

client = OpenAI(base_url="http://vega:8000/v1", api_key="not-needed")

with ThreadPoolExecutor(max_workers=8) as pool:
    futures = {
        pool.submit(client.embeddings.create, model="embed-model", input=[doc]): "embed",
        pool.submit(client.chat.completions.create, model="gpt-oss-120b", messages=[...]): "analysis",
        pool.submit(client.chat.completions.create, model="qwen-vl", messages=[...]): "vision",
    }
    results = {futures[f]: f.result() for f in as_completed(futures)}
```

### 3b. Ray Jobs API (for batch workloads)

Submit Python scripts that run entirely on the cluster. The job survives
if your Mac disconnects.

```python
from ray.job_submission import JobSubmissionClient

client = JobSubmissionClient("http://vega:8265")
job_id = client.submit_job(
    entrypoint="python batch_pipeline.py --all",
    runtime_env={
        "working_dir": "./",           # zips and uploads code
        "pip": ["openai", "pydantic"], # installs on cluster
    },
)

# Job survives Mac disconnection
status = client.get_job_status(job_id)
logs = client.get_job_logs(job_id)
```

Or via CLI:

```bash
ray job submit --address http://vega:8265 \
  --working-dir . \
  -- python batch_pipeline.py --all
```

### 3c. Ray Data (for high-throughput batch)

For processing hundreds of documents, Ray Data eliminates all HTTP overhead.
Data and compute are co-located on the cluster:

```python
import ray
from ray.data.llm import vLLMEngineProcessorConfig, build_llm_processor

config = vLLMEngineProcessorConfig(
    model_source="ggml-org/gpt-oss-120b-GGUF",
    max_model_len=131072,
    gpu_memory_utilization=0.9,
)

processor = build_llm_processor(
    config,
    preprocess=my_preprocess,
    postprocess=my_postprocess,
)

ds = ray.data.read_json("/mnt/shared/input/*.json")
result = processor(ds)
result.write_json("/mnt/shared/output/")
```

### What NOT to Use

- **Ray Client** (`ray.init("ray://...")`): fragile -- 30s timeout kills
  everything if your Mac sleeps. Not recommended for ML workloads even by
  Ray's own docs.
- **Individual HTTP API calls in a loop**: what we have today. Works but
  wastes GPU time between sequential calls.

### Steps

```
[ ] 1. Refactor pipeline code to use AsyncOpenAI with concurrent requests
       - Replace sequential API calls with asyncio.gather()
       - Point at Ray Serve endpoint (http://vega:8000/v1)
       - This alone will dramatically improve throughput

[ ] 2. Add justfile recipe for parallel pipeline execution
       just cluster-batch-parallel

[ ] 3. For batch workloads: write a Ray Job submission wrapper
       - Package pipeline scripts for cluster execution
       - Results written to NFS shared filesystem (/mnt/shared/output)
       - justfile recipe: just cluster-batch-submit

[ ] 4. For large-scale batch: adopt Ray Data for LLM inference
       - Only when regularly processing hundreds of items
       - Replaces HTTP calls entirely for batch processing
       - Data stays on cluster, GPU stays saturated
```

---

## Approach Comparison

| Approach               | Setup     | Network Overhead | GPU Utilization | Best For                 |
| ---------------------- | --------- | ---------------- | --------------- | ------------------------ |
| Justfile + SSH         | Trivial   | None             | Depends on code | Quick jobs, prototyping  |
| NFS + SSH              | Easy      | Low (staged)     | Depends on code | Data-heavy workflows     |
| API calls (parallel)   | None      | Medium           | 60-85%          | Online / interactive     |
| Ray Jobs               | Moderate  | Low (code once)  | 85-92%          | Production batch         |
| Ray Data               | Moderate  | None (co-located)| 85-92%          | High-throughput batch    |

## References

- [DGX Spark LLM Guide -- Parallel Pipeline Pattern](../docs/DGX_SPARK_LLM_GUIDE.md)
- [Ray Jobs API](https://docs.ray.io/en/latest/cluster/running-applications/job-submission/index.html)
- [Ray Data LLM batch inference](https://docs.ray.io/en/latest/data/batch_inference.html)
