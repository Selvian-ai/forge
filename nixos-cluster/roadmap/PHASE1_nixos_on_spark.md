# Phase 1: NixOS on DGX Spark

**Status:** not started
**Difficulty:** Moderate -- someone has already done this
**Time estimate:** 1-2 days for install + integration, half a day for tuning
**Prerequisite:** DGX Spark hardware

---

## Why

The cluster runs NixOS. The Spark ships with DGX OS (Ubuntu-based). Running
NixOS on the Spark means one flake, one config language, one deployment
process for the entire cluster.

## Feasibility

[graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark) is a
working NixOS flake for the DGX Spark with confirmed installs on both DGX
Spark and ASUS Ascent GX10 (same GB10 SoC). The path is proven.

| Area                        | Status                                   |
| --------------------------- | ---------------------------------------- |
| NixOS aarch64 support       | First-class, tier-1 platform             |
| NVIDIA Blackwell drivers    | Open kernel modules, works               |
| CUDA 13                     | Available via overlay in the flake        |
| Kernel 6.17+                | NVIDIA custom kernel, automated in flake |
| nvidia-container-toolkit    | Fully supported on aarch64               |
| UEFI / systemd-boot        | Works, disable Secure Boot               |
| ConnectX-7 basic networking | In-tree mlx5 driver works                |
| ConnectX-7 advanced RDMA    | Needs MLNX_OFED (not packaged for NixOS) |
| Community validation        | Confirmed Oct 2025, active maintenance   |

## Key Gotchas

1. **No binary cache for aarch64 CUDA.** First build takes hours -- all
   CUDA packages compile from source. Set up a local Cachix after first build.

2. **Must use `hardware.nvidia.open = true`** -- Blackwell requires open
   kernel modules. Proprietary modules are unsupported.

3. **Must use NVIDIA's custom kernel** (6.17.1 from `NVIDIA/NV-Kernels`).
   Standard NixOS kernel boots but Ethernet has problems.

4. **MLNX_OFED not available** if we need advanced InfiniBand features.
   Basic 200GbE via in-tree `mlx5_core` works fine.

## What Differs from Our Existing Nodes

| Config Area           | vega/rigel/arcturus (x86)          | spark (aarch64)                          |
| --------------------- | ---------------------------------- | ---------------------------------------- |
| Architecture          | x86_64                             | aarch64                                  |
| NVIDIA driver         | `nvidiaPackages.production` (proprietary) | `nvidiaPackages.production` + `open = true` |
| CUDA                  | 12.x                               | 13.0+ (overlay from dgx-spark flake)    |
| Kernel                | Stock NixOS                        | NVIDIA custom 6.17 from NV-Kernels      |
| Boot                  | systemd-boot                       | systemd-boot (disable Secure Boot)       |
| Blacklisted modules   | --                                 | `nouveau`, `r8169`, `coresight_etm4x`   |
| Container runtime     | Podman + dockerCompat              | Podman + dockerCompat (same)             |

## Steps

```
[ ] 1. Fork or use graham33/nixos-dgx-spark flake as starting point
       nix flake init -t github:graham33/nixos-dgx-spark#dgx-spark

[ ] 2. Integrate with our existing nixos-cluster flake structure
       - Add spark as a new host in configuration/hosts/spark/
       - Import the dgx-spark NixOS module into the host config
       - Merge common.nix config (users, k3s, monitoring, etc.)
       - Keep the CUDA 13 overlay and NVIDIA kernel from the dgx-spark flake

[ ] 3. Build USB installer image (can cross-compile from x86)
       nix build .#packages.aarch64-linux.usb-image

[ ] 4. Disable Secure Boot in DGX Spark BIOS, boot from USB, install
       - Follow standard NixOS installation steps
       - Partition NVMe, mount, nixos-install

[ ] 5. Apply kernel tuning (add to spark's configuration.nix):
       - NVMe read-ahead: systemd oneshot to set 8192
       - Ensure --no-mmap is used for all model loading
       - CPU idle states config for low-latency networking

[ ] 6. Set up local Cachix to cache aarch64 CUDA builds
       - Avoids multi-hour rebuilds on nixos-rebuild
       - All future rebuilds pull from cache

[ ] 7. Verify hardware:
       - nvidia-smi (GPU detected, driver loaded)
       - llama-bench with a small model (GPU compute works)
       - Container GPU passthrough (podman run --gpus all ...)

[ ] 8. Join to k3s cluster
       - Configure as worker node
       - Label: gpu.model=spark, accelerator=nvidia
       - Verify node visible in kubectl get nodes
```

## References

- [graham33/nixos-dgx-spark](https://github.com/graham33/nixos-dgx-spark)
- [NVIDIA NV-Kernels](https://github.com/NVIDIA/NV-Kernels) (custom kernel source)
- [DGX Spark porting guide](https://docs.nvidia.com/dgx/dgx-spark-porting-guide/optimization.html)
- [DGX Spark LLM Guide](../docs/DGX_SPARK_LLM_GUIDE.md) (kernel tuning details)
