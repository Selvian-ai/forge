# GPU Cluster Roadmap

Roadmap for turning the NixOS cluster into a multi-modal inference platform.

## Current State

- **Cluster nodes:** vega (RTX 3060, control plane), rigel (RTX 3080),
  arcturus (RTX 2080) -- all NixOS with k3s
- **DGX Spark:** incoming, currently ships with DGX OS (Ubuntu-based)
- **Inference:** Ollama in Docker, sequential requests, terrible performance
- **Pipelines:** run on macOS workstation, call inference APIs over HTTP
  sequentially -- GPU sits idle between calls

## Target State

- DGX Spark running NixOS (matching the rest of the cluster)
- Ray Serve + vLLM multi-modal platform across all GPU nodes
- Pipelines fire parallel requests (embeddings, vision, LLM concurrently)
- Batch workloads run directly on the cluster (zero network overhead)
- Simple `just` commands to submit jobs from macOS

## Phases

| Phase | Doc | Status | Difficulty | Time Est. | Prerequisite |
| ----- | --- | ------ | ---------- | --------- | ------------ |
| 1     | [NixOS on DGX Spark](./PHASE1_nixos_on_spark.md) | **not started** | Moderate | 1-2 days | DGX Spark hardware |
| 2     | [Ray Serve Multi-Modal](./PHASE2_ray_serve.md) | **not started** | Moderate | 2-3 days | Phase 1 |
| 3     | [Pipeline Integration](./PHASE3_pipeline_integration.md) | **not started** | Easy-Moderate | 1-3 days | Partial: layers 1-2 start now |

Phases 3a (Justfile + SSH) and 3b (NFS) can start immediately -- no
dependency on the DGX Spark or Ray being set up.

## Reference

- [DGX Spark LLM Guide](../docs/DGX_SPARK_LLM_GUIDE.md) -- hardware tuning,
  llama.cpp, Ray Serve configuration, benchmarks
