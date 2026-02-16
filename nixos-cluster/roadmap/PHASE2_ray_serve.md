# Phase 2: Ray Serve Multi-Modal Platform

**Status:** not started
**Difficulty:** Moderate
**Time estimate:** 2-3 days for setup, 1 day for model deployment and tuning
**Prerequisite:** Phase 1 (NixOS on DGX Spark)

---

## Why

Our pipelines need more than text generation: vision/OCR, embeddings for RAG,
audio transcription, structured JSON output. Ray Serve + vLLM provides all of
this behind a single OpenAI-compatible API with continuous batching -- so our
automated system can fire parallel requests and keep the GPU saturated instead
of serializing everything.

## Architecture Decision: Standalone Ray, Not KubeRay

KubeRay adds no value for a 3-4 node static cluster. It introduces
double-scheduling conflicts (k3s vs Ray), extra YAML, and debugging overhead.
Use **containerized Ray managed by systemd** instead.

## Per-Node Requirements

| Component          | vega (RTX 3060, 12GB)    | rigel (RTX 3080, 10GB)    | arcturus (RTX 2080, 8GB)   | spark (Blackwell, 128GB)         |
| ------------------ | ------------------------ | ------------------------- | -------------------------- | -------------------------------- |
| Role               | Ray head                 | Ray worker                | Ray worker                 | Ray worker (primary GPU)         |
| Container image    | vllm/vllm-openai (x86)  | vllm/vllm-openai (x86)   | vllm/vllm-openai (x86)    | nvcr.io/nvidia/vllm:25.11 (arm64) |
| CUDA               | 12.x (existing)          | 12.x (existing)           | 12.x (existing)            | 13.0+ (in container)             |
| Models             | Embeddings, Whisper      | Small LLM (7B Q4)        | Small LLM (3-7B Q4)       | Large LLM, Vision, all big models |
| Ray ports          | 6379, 8265, 8000, 10001 | --                        | --                         | --                               |
| Dynamic port range | 10002-19999              | 10002-19999               | 10002-19999                | 10002-19999                      |

### Firewall Config (all nodes)

```nix
# Add to common.nix or per-host config
networking.firewall.allowedTCPPortRanges = [
  { from = 6379; to = 6379; }   # Ray GCS
  { from = 8000; to = 8000; }   # Ray Serve API
  { from = 8265; to = 8265; }   # Ray Dashboard + Jobs API
  { from = 10001; to = 10001; } # Ray Client
  { from = 10002; to = 19999; } # Ray dynamic worker ports
];
```

## Critical Constraints

- **vLLM cannot split a model across heterogeneous GPUs.** Each model must
  fit entirely on one GPU. This is fine -- the Spark handles big models,
  smaller nodes handle small models.

- **Cross-architecture (x86 + ARM64):** Ray supports it but **versions must
  match exactly** across all nodes. Pin the Ray version in both container
  images.

- **Consumer GPUs (RTX 30xx/20xx) need custom labels** -- they're not in
  Ray's predefined accelerator types. Use custom labels and label selectors
  to pin models to specific nodes:
  ```bash
  ray start --address=vega:6379 --labels='{"gpu_model":"rtx3080"}'
  ```

## Model Placement Plan

| Model                     | Size     | Runs On     | Purpose             |
| ------------------------- | -------- | ----------- | ------------------- |
| gpt-oss-120b MXFP4       | ~65 GiB  | spark       | Primary reasoning   |
| Qwen2.5-VL-7B            | ~15 GiB  | spark       | Vision / OCR        |
| Voxtral-Mini-3B           | ~7 GiB   | spark       | Audio transcription |
| Qwen2.5-0.5B (embed)     | ~2 GiB   | vega        | Embeddings for RAG  |
| Qwen2.5-7B-Instruct Q4   | ~4 GiB   | rigel       | Fast text tasks     |
| Qwen2.5-3B-Instruct Q4   | ~2 GiB   | arcturus    | Light text tasks    |

### Spark Memory Budget (128GB)

| Allocation                | Size     |
| ------------------------- | -------- |
| gpt-oss-120b MXFP4       | ~65 GiB  |
| Qwen2.5-VL-7B            | ~15 GiB  |
| Voxtral-Mini-3B           | ~7 GiB   |
| KV cache + runtime        | ~30 GiB  |
| **Total**                 | ~117 GiB |
| **Headroom**              | ~11 GiB  |

Use `min_replicas: 0` for Voxtral so Ray scales it down when idle,
freeing memory for larger KV caches on the reasoning model.

## systemd Service (Head Node -- vega)

```nix
# In vega's configuration.nix
systemd.services.ray-head = {
  description = "Ray cluster head node";
  after = [ "network.target" "nvidia-persistenced.service" ];
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "simple";
    ExecStart = ''
      ${pkgs.podman}/bin/podman run --rm \
        --gpus all \
        --network host \
        --name ray-head \
        -v /mnt/shared/hf-cache:/root/.cache/huggingface \
        -e HF_TOKEN=$(cat /mnt/shared/hf-cache/token) \
        -e RAY_memory_monitor_refresh_ms=0 \
        vllm/vllm-openai:latest \
        ray start --head --port=6379 --dashboard-host=0.0.0.0 \
          --labels='{"gpu_model":"rtx3060"}' --block
    '';
    ExecStop = "${pkgs.podman}/bin/podman stop ray-head";
    Restart = "on-failure";
    RestartSec = 15;
    LimitNOFILE = 65536;
  };
};
```

## systemd Service (Worker -- e.g. spark)

```nix
# In spark's configuration.nix
systemd.services.ray-worker = {
  description = "Ray cluster worker node";
  after = [ "network.target" "nvidia-persistenced.service" ];
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "simple";
    ExecStart = ''
      ${pkgs.podman}/bin/podman run --rm \
        --gpus all \
        --network host \
        --name ray-worker \
        -v /mnt/shared/hf-cache:/root/.cache/huggingface \
        -e HF_TOKEN=$(cat /mnt/shared/hf-cache/token) \
        -e RAY_memory_monitor_refresh_ms=0 \
        nvcr.io/nvidia/vllm:25.11-py3 \
        ray start --address=vega:6379 \
          --labels='{"gpu_model":"spark"}' --block
    '';
    ExecStop = "${pkgs.podman}/bin/podman stop ray-worker";
    Restart = "on-failure";
    RestartSec = 15;
    LimitNOFILE = 65536;
  };
};
```

## Steps

```
[ ] 1. Open Ray firewall ports on all nodes
       - Add networking.firewall config shown above to common.nix
       - nixos-rebuild switch on all nodes

[ ] 2. Set up HuggingFace credentials and shared cache
       - Create a HuggingFace account + access token at https://huggingface.co/settings/tokens
         (needed for gated models like Llama, Mistral, some Qwen variants)
       - Store the token in 1Password (item: "huggingface-token", field: "credential")
       - Write token to shared cache so all nodes/containers can use it:
           op item get "huggingface-token" --field credential --reveal \
             > /mnt/shared/hf-cache/token
       - Pass to containers via: -e HF_TOKEN=$(cat /mnt/shared/hf-cache/token)
       - Set up /mnt/shared/hf-cache on NFS (see Phase 3 NFS setup)
         Or local /var/lib/hf-cache per node (simpler, duplicates models)

[ ] 3. Pull/build container images
       - x86 nodes: docker pull vllm/vllm-openai:latest
       - spark: docker pull nvcr.io/nvidia/vllm:25.11-py3
       - Verify Ray version matches across both images
       - Push to Harbor with multi-arch manifests if possible

[ ] 4. Create systemd services on each node
       - vega: ray-head service (template above)
       - rigel, arcturus: ray-worker services (x86 image)
       - spark: ray-worker service (ARM64 image)

[ ] 5. Verify cluster formation
       - Ray Dashboard at http://vega:8265
       - All 4 nodes visible with correct GPU labels
       - ray status shows all GPUs

[ ] 6. Deploy Ray Serve multi-modal config
       - Use the Python config from DGX_SPARK_LLM_GUIDE.md
       - Configure model -> node placement via labels
       - Set autoscaling per model

[ ] 7. Verify all endpoints
       curl http://vega:8000/v1/models
       - Test chat completions (reasoning model)
       - Test embeddings
       - Test vision (image + text)
       - Test audio transcription (if deployed)

[ ] 8. Benchmark
       - Run concurrent requests from pipeline code
       - Compare throughput vs current Ollama sequential baseline
       - Measure GPU utilization on all nodes (nvidia-smi dmon)
```

## References

- [DGX Spark LLM Guide -- Ray Serve section](../docs/DGX_SPARK_LLM_GUIDE.md)
- [Ray Serve LLM docs](https://docs.ray.io/en/latest/serve/llm/serving-llms.html)
- [Ray Serve vLLM compatibility](https://docs.ray.io/en/latest/serve/llm/user-guides/vllm-compatibility.html)
- [vllm-dgx-spark community repo](https://github.com/mark-ramsey-ri/vllm-dgx-spark)
- [NVIDIA vLLM DGX Spark playbook](https://build.nvidia.com/spark/vllm)
