# Windows Guest Setup Guide for Looking Glass + VFIO

This guide covers setting up your Windows Virtual Machine (Windows 10/11) to work with GPU Passthrough and the Looking Glass Host service.

---

## Prerequisites in Host / VM XML

Before booting your VM:
1. Ensure the IVSHMEM device (`<shm name='looking-glass'>...`) is added to your VM definition.
2. Ensure the GPU and Audio PCI hostdev devices are assigned.
3. Use UEFI (OVMF) firmware and Q35 machine architecture.

---

## Step 1: Install VirtIO & IVSHMEM Drivers

1. Download the latest stable **virtio-win.iso** from Fedora:
   - URL: `https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso`
   - Attach this ISO to your VM as a virtual CD-ROM drive.
2. Boot into Windows.
3. Open **Device Manager** (`devmgmt.msc`).
4. Look for an unrecognized PCI device under **System Devices** or **Other Devices** with Hardware ID `PCI\VEN_1AF4&DEV_1110`:
   - Right-click the device -> **Update driver**.
   - Select **Browse my computer for drivers**.
   - Point the folder to the VirtIO CD-ROM drive: `D:\ivshmem\w10\amd64` (or `w11`).
   - Complete installation. The device should now appear as **IVSHMEM Device** without errors.

---

## Step 2: Ensure an Active Display on the Passthrough GPU

NVIDIA/AMD drivers only render 3D desktop frames if Windows detects an active connected monitor.

Choose one of the following methods:

### Option A: HDMI / DisplayPort Dummy Plug (Recommended for stability)
- Plug an inexpensive ($5) HDMI or DisplayPort EDID dummy plug directly into the dedicated GPU's physical port.
- This tricks Windows into treating the GPU as connected to a real 1080p, 1440p, or 4K high-refresh display.

### Option B: Virtual Display Driver (Indirect Display Driver - IddSampleDriver)
- If your laptop has no external port wired directly to the dGPU, install a software virtual display driver such as:
  - **Virtual Display Driver (VDD)**: `https://github.com/itsmikethetech/Virtual-Display-Driver`
  - Or **IddSampleDriver**: `https://github.com/roshkins/IddSampleDriver`
- Configure the resolution and refresh rate (e.g. 2560x1440 @ 120Hz/144Hz) inside the driver configuration file.

---

## Step 3: Install Looking Glass Host Application

1. Download the Looking Glass Host installer from the official release page:
   - Official Site: `https://looking-glass.io/downloads`
   - Download `looking-glass-host-setup.exe` (matching your client version, e.g., B6).
2. Run the installer as **Administrator**.
3. During setup:
   - Select **Install as Windows Service** (this allows Looking Glass to start before logging in).
   - Allow any firewall prompts if requested.
4. Verify the service is running:
   - Press `Win + R`, type `services.msc`, and look for **Looking Glass (host)**.
   - Status should be **Running**, and Startup type **Automatic**.

---

## Step 4: Install NVIDIA / AMD GPU Drivers

1. Download the official graphics drivers from NVIDIA or AMD for your GPU model.
2. Install the driver inside Windows as normal.
3. Verify in Device Manager that your GPU shows up cleanly under **Display Adapters** without Code 43.

---

## Step 5: Connecting from the Linux Host

On your Linux host:
1. Start your Windows VM:
   ```bash
   virsh start <vm_name>
   ```
2. Launch Looking Glass Client:
   ```bash
   ./run-looking-glass.sh
   ```
3. Default Controls:
   - **Right Control**: Toggle input capture (mouse and keyboard lock into the VM).
   - **Right Control + F**: Toggle fullscreen mode.
   - **Right Control + Q**: Quit client.

---

## Troubleshooting Guest Issues

- **Code 43 Error on NVIDIA GPU**:
  - Ensure your XML includes `<kvm><hidden state='on'/></kvm>` and `<hyperv><vendor_id state='on' value='GenuineIntel'/></hyperv>`.
- **Looking Glass shows "Waiting for host..."**:
  - Ensure the Looking Glass Host service is running in Windows.
  - Verify that IVSHMEM driver is installed in Windows Device Manager.
  - Check that `/dev/shm/looking-glass` on the host has `0660` permissions owned by your host user and `kvm` group.
- **Black Screen / No Frames**:
  - Make sure Windows has an active display (Dummy plug or Virtual Display Driver enabled).
  - Open Windows Display Settings and ensure the passthrough GPU is set as the primary or active display.
