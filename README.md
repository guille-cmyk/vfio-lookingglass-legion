# High-Performance Windows 11 VFIO + Looking Glass Toolkit

[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-orange.svg)](https://kernel.org)
[![Hypervisor: KVM / QEMU](https://img.shields.io/badge/Hypervisor-KVM%20%2F%20QEMU-blue.svg)](https://www.qemu.org/)
[![Looking Glass: B7](https://img.shields.io/badge/Looking%20Glass-B7-brightgreen.svg)](https://looking-glass.io/)
[![Hardware: NVIDIA RTX 3080 Mobile](https://img.shields.io/badge/GPU-RTX%203080%20Mobile-green.svg)](https://nvidia.com)

A production-grade, automated, and modular toolkit designed to run a **near-native bare-metal performance Windows 11 gaming & workstation VM** inside Linux using **dedicated laptop NVIDIA GPU passthrough (VFIO)**, **Looking Glass B7 low-latency frame relay**, and **physical NVMe SSD dual-boot support**.

Tailored specifically for dual-GPU laptops (such as the **Lenovo Legion 7** with Intel UHD Graphics + NVIDIA GeForce RTX 3080 Mobile), but modular and adaptable to any hybrid or dual-GPU system.

---

## Architecture Overview

```
                      ┌────────────────────────────────────────┐
                      │             Linux Host                 │
                      │  (Intel UHD Graphics / Wayland / X11)  │
                      └──────────────────┬─────────────────────┘
                                         │
                        Looking Glass Client (B7 EGL)
                                         │
                 ┌───────────────────────┴───────────────────────┐
                 │       IVSHMEM Shared Memory (/dev/shm)        │
                 │              (64MB Direct DMA)                │
                 └───────────────────────┬───────────────────────┘
                                         │
                        Looking Glass Host Service (DXGI)
                                         │
                      ┌──────────────────┴─────────────────────┐
                      │       Windows 11 KVM Guest VM          │
                      │  - NVIDIA GeForce RTX 3080 Mobile      │
                      │  - GA104 HD Audio Controller           │
                      │  - 1TB Micron NVMe SSD (Physical Raw)  │
                      │  - 12 vCPUs pinned 1:1 to Hyperthreads │
                      │  - 16 GB Locked Memory (No Swap/Page)  │
                      │  - Virtual TPM 2.0 + UEFI Secure Boot  │
                      └────────────────────────────────────────┘
```

---

## Key Features

1. **One-Command Daily Launch (`win11`)**:
   - Single command starts the VM, handles pre-flight disk safety, tunes CPU governors to `performance`, compacts RAM, and launches Looking Glass with hardware EGL.
   - Clean session cleanup restores host power efficiency (`powersave`) on exit.
2. **Dual-Mode GPU Management (`vfio-ctl`)**:
   - **VM Mode (`--mode-vm`)**: Binds NVIDIA GPU + Audio to `vfio-pci` at boot for 100% stable, bare-metal VM passthrough.
   - **Host Mode (`--mode-host`)**: Restores NVIDIA GPU to the Linux host for native CUDA, Blender, and Ollama workloads.
   - **Live Status (`--status`)**: Inspects current driver bindings, IOMMU isolation, and VM state in real time.
3. **Physical NVMe Passthrough with Bare-Metal Dual Boot**:
   - Directly maps your dedicated Windows NVMe drive (`/dev/disk/by-id/nvme-...`) with raw `cache=none` and `io=native` throughput.
   - Self-contained EFI partition allows you to boot Windows 11 **inside the Linux VM via Looking Glass** OR **bare-metal directly via F12 at boot**.
4. **Hardware-Tuned Performance**:
   - **12 vCPU 1:1 Pinning**: VM vCPUs pinned to Intel Core i7-11800H cores (`2-7, 10-15`), leaving cores `0, 1, 8, 9` dedicated to Linux desktop and emulator threads.
   - **Memory Locking**: 16 GB memory reservation locked with `<nosharepages/>` and `<locked/>`.
   - **Hyper-V Enlightenments**: Full enlightenments (`relaxed`, `vapic`, `spinlocks`, `vendor_id GenuineIntel`, `kvm hidden`) preventing NVIDIA Code 43.
   - **Audio Redirection**: ICH9 HD Audio mapped directly to host PipeWire via SPICE.

---

## Global CLI Commands

After installation, the following commands are available globally in your PATH:

| Command | Purpose | Example |
|---|---|---|
| `win11` | Start Windows 11 VM and launch Looking Glass | `win11` |
| `win11 -c` | Open VM in SPICE graphical console (`virt-manager`) | `win11 --console` |
| `vfio-ctl` | Main toolkit CLI & interactive menu | `vfio-ctl --status` |
| `looking-glass-run` | Launch standalone Looking Glass client | `looking-glass-run` |
| `vfio-xml` | Generate optimized Libvirt domain XML | `vfio-xml` |

---

## Quickstart Guide

### 1. Clone the Repository
```bash
git clone https://github.com/guille-cmyk/vfio-lookingglass-legion.git
cd vfio-lookingglass-legion
```

### 2. Verify Hardware & IOMMU Grouping
Check that your CPU virtualization, IOMMU groups, and GPU isolation are supported:
```bash
./setup.sh --check
```

### 3. Check Live Status
```bash
./setup.sh --status
```

### 4. Switch to VM Mode (Isolate NVIDIA GPU)
To isolate your NVIDIA RTX 3080 for exclusive Windows VM use:
```bash
sudo ./setup.sh --mode-vm
```
*Note: A system reboot is required for `vfio-pci` to bind to the GPU during early initramfs boot.*

### 5. Launch Windows 11
After rebooting:
```bash
win11
```
- Toggle input capture (mouse/keyboard lock): **Right Control (`RCtrl`)**.
- Toggle Fullscreen: **Right Control + F**.

### 6. Switch Back to Linux Host Mode (Optional)
When you need the NVIDIA GPU back on Linux for Blender or CUDA:
```bash
sudo vfio-ctl --mode-host
```
Reboot to return the GPU to the proprietary `nvidia` driver.

---

## Windows Guest Setup

1. **Install Looking Glass Host**:
   - Open **This PC** $\rightarrow$ **Drive D: (`LG_TOOLS`)** inside Windows.
   - Right-click `looking-glass-host-setup.exe` and select **"Run as administrator"**.
   - The installer automatically configures the IVSHMEM driver and starts the background host service.
2. **Install NVIDIA Drivers**:
   - Run Windows Update or download official Game Ready / Studio drivers from [nvidia.com](https://www.nvidia.com).
3. **Display Configuration**:
   - Install the Looking Glass IDD (Indirect Display Driver) or use an EDID dummy plug for native high-refresh rate support.

See [`docs/GUEST_SETUP.md`](docs/GUEST_SETUP.md) for full Windows guest details.

---

## Troubleshooting & Safety

- **Anti-Corruption NVMe Protection**: Includes automated udev rules (`/etc/udev/rules.d/99-nvme0n1-noautomount.rules`) and pre-flight safety checks to ensure Linux never mounts the physical Windows drive while the VM is running.
- **Shared Memory Permissions**: IVSHMEM shared memory `/dev/shm/looking-glass` is configured with `0660 $USER:kvm`.
- **Direct SPICE Fallback**: Run `win11 --console` anytime to access the VM via `virt-manager` if Looking Glass Host is not running.

---

## License

GPL-2.0 / MIT.
Created for optimal VFIO performance on Linux.
