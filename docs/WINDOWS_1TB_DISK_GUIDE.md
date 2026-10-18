# Guide: Passing Your 1TB Windows 11 Pro Physical Disk to KVM/VFIO

This guide provides everything needed to boot your existing Windows 11 Pro installation from your physical 1TB Micron NVMe SSD (`nvme0n1`) inside your VFIO/KVM virtual machine.

---

## 1. Discovered Disk Details

- **Physical Device**: `/dev/nvme0n1`
- **Persistent By-ID Path**: `/dev/disk/by-id/nvme-Micron_MTFDKBA1T0TFH_22043449645A`
- **Capacity**: 1 TB (953.9 GiB)
- **Partitions**:
  - `nvme0n1p1` (16 MB): Microsoft Reserved (MSR)
  - `nvme0n1p2` (953.9 GB): Windows 11 Pro NTFS Partition

---

## 2. CRITICAL: Prevent Host Automount (Avoid Disk Corruption)

> [!CAUTION]
> **Filesystem Safety**:
> If the Linux host has `/dev/nvme0n1p2` mounted while Windows 11 boots inside the virtual machine, **both OSes will write to the disk simultaneously, causing catastrophic NTFS corruption**.

### Prevent Linux from Automounting the Windows Disk
Create a udev rule to tell UDisks2 to ignore `nvme0n1`:

```bash
sudo bash -c 'cat <<EOF > /etc/udev/rules.d/99-nvme0n1-noautomount.rules
# Prevent host from automounting the Windows 11 NVMe disk
KERNEL=="nvme0n1*", ENV{UDISKS_IGNORE}="1"
EOF'
sudo udevadm control --reload-rules && sudo udevadm trigger
```

If it is currently mounted, unmount it right now:
```bash
sudo umount /dev/nvme0n1p2
```

---

## 3. The EFI Bootloader Situation

Because `nvme0n1` was partitioned without a standalone FAT32 EFI partition (or its EFI bootloader was located on another drive previously), the VM's OVMF UEFI firmware cannot find `bootmgfw.efi` directly on `nvme0n1` without assistance.

### Solution: Create a Tiny 100MB Virtual EFI Bootloader Disk (Recommended)

This allows OVMF to load Windows 11 **without resizing or repartitioning your 1TB physical drive**.

#### Step A: Create the 100MB Virtual Boot Disk
```bash
sudo qemu-img create -f qcow2 /var/lib/libvirt/images/win11-efi-boot.qcow2 100M
```

#### Step B: Attach Both Disks in Your VM XML (`virsh edit <vm_name>`)
Inside `<devices>`:
```xml
<!-- 1. The 100MB Virtual EFI Boot Disk (Boots First) -->
<disk type='file' device='disk'>
  <driver name='qemu' type='qcow2'/>
  <source file='/var/lib/libvirt/images/win11-efi-boot.qcow2'/>
  <target dev='vda' bus='virtio'/>
  <boot order='1'/>
</disk>

<!-- 2. The 1TB Physical Windows Disk (Initial Boot with SATA) -->
<disk type='block' device='disk'>
  <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
  <source dev='/dev/disk/by-id/nvme-Micron_MTFDKBA1T0TFH_22043449645A'/>
  <target dev='sda' bus='sata'/>
  <boot order='2'/>
</disk>
```

#### Step C: Populate the Bootloader
1. Attach the official **Windows 11 Install ISO** as a virtual CD-ROM in your VM.
2. Boot into the Windows Installer -> Click **Next** -> Click **Repair your computer** (bottom left).
3. Select **Troubleshoot** -> **Advanced Options** -> **Command Prompt**.
4. Initialize the 100MB EFI disk and write the bootloader:
   ```cmd
   diskpart
   select disk 0
   clean
   convert gpt
   create partition efi
   format quick fs=fat32 label="ESP"
   assign letter=S
   list volume
   exit
   ```
   *(Note the drive letter of your 1TB Windows partition, usually `C:` or `D:`)*
5. Rebuild the BCD boot files pointing to your 1TB drive:
   ```cmd
   bcdboot C:\Windows /s S: /f UEFI
   ```
6. Reboot! Windows 11 Pro will now boot smoothly from your 1TB drive!

---

## 4. Avoiding the `INACCESSIBLE_BOOT_DEVICE` Blue Screen

When you first boot Windows 11 inside KVM:
- **Use `bus='sata'`**: Because Windows has built-in AHCI/SATA drivers, it boots without requiring third-party drivers.
- **Install VirtIO Drivers**:
  1. Attach `virtio-win.iso` to the VM.
  2. In Windows, open `virtio-win.iso` and run `virtio-win-gt-x64.exe` to install all Red Hat VirtIO drivers (Storage, Network, Memory Balloon, IVSHMEM).
- **Upgrade to `bus='virtio'` for Maximum NVMe Performance**:
  Once the driver is installed, edit the VM XML (`virsh edit <vm_name>`):
  Change:
  ```xml
  <target dev='sda' bus='sata'/>
  ```
  To:
  ```xml
  <target dev='vdb' bus='virtio'/>
  ```
  This unleashes native PCIe Gen4 NVMe performance (>3500 MB/s, near-zero virtualization overhead).

---

## 5. Summary Checklist

- [ ] Unmount `/dev/nvme0n1p2` on the Linux host.
- [ ] Apply the udev rule so Linux doesn't auto-mount the partition.
- [ ] Add the physical disk block device to your VM XML.
- [ ] Create or link the EFI bootloader.
- [ ] Boot Windows 11 with `looking-glass-run`!
