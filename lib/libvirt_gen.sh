#!/usr/bin/env bash
# lib/libvirt_gen.sh - Libvirt XML generation for IVSHMEM, PCI Passthrough, and Physical Disk

generate_ivshmem_xml() {
    local shm_size="${1:-64}"
    cat <<EOF
    <!-- Looking Glass IVSHMEM Device -->
    <shmem name='looking-glass'>
      <model type='ivshmem-plain'/>
      <size unit='M'>${shm_size}</size>
    </shmem>
EOF
}

generate_hostdev_pci_xml() {
    local pci_id="$1" # e.g. 0000:01:00.0 or 01:00.0
    local stripped="${pci_id#0000:}"
    local bus slot func
    bus=$(echo "$stripped" | cut -d':' -f1)
    slot=$(echo "$stripped" | cut -d':' -f2 | cut -d'.' -f1)
    func=$(echo "$stripped" | cut -d'.' -f2)

    cat <<EOF
    <!-- PCI Passthrough Device ${pci_id} -->
    <hostdev mode='subsystem' type='pci' managed='yes'>
      <source>
        <address domain='0x0000' bus='0x${bus}' slot='0x${slot}' function='0x${func}'/>
      </source>
    </hostdev>
EOF
}

generate_hyperv_features_xml() {
    cat <<EOF
  <!-- Hyper-V enlightenments for Windows Guest Performance & GPU compatibility -->
  <features>
    <acpi/>
    <apic/>
    <hyperv mode='custom'>
      <relaxed state='on'/>
      <vapic state='on'/>
      <spinlocks state='on' retries='8191'/>
      <vendor_id state='on' value='GenuineIntel'/>
    </hyperv>
    <kvm>
      <hidden state='on'/>
    </kvm>
    <ioapic driver='kvm'/>
  </features>
EOF
}

generate_optimized_cpu_tuning_xml() {
    cat <<'EOF'
  <!-- 1:1 SMT CPU Pinning for Intel Core i7-11800H (6 Cores / 12 vCPUs for VM, 2 Cores for Host) -->
  <vcpu placement='static'>12</vcpu>
  <cputune>
    <vcpupin vcpu='0' cpuset='2'/>
    <vcpupin vcpu='1' cpuset='10'/>
    <vcpupin vcpu='2' cpuset='3'/>
    <vcpupin vcpu='3' cpuset='11'/>
    <vcpupin vcpu='4' cpuset='4'/>
    <vcpupin vcpu='5' cpuset='12'/>
    <vcpupin vcpu='6' cpuset='5'/>
    <vcpupin vcpu='7' cpuset='13'/>
    <vcpupin vcpu='8' cpuset='6'/>
    <vcpupin vcpu='9' cpuset='14'/>
    <vcpupin vcpu='10' cpuset='7'/>
    <vcpupin vcpu='11' cpuset='15'/>
    <emulatorpin cpuset='0,1,8,9'/>
  </cputune>
  <cpu mode='host-passthrough' check='none' migratable='on'>
    <topology sockets='1' dies='1' cores='6' threads='2'/>
  </cpu>
EOF
}

generate_physical_disk_xml() {
    local disk_path="${1:-/dev/disk/by-id/nvme-Micron_MTFDKBA1T0TFH_22043449645A}"
    cat <<EOF
    <!-- ================================================================= -->
    <!-- PHYSICAL 1TB WINDOWS 11 DISK PASSTHROUGH                          -->
    <!-- ================================================================= -->
    <!-- STAGE 1: Initial Boot (Uses 'sata' bus so Windows boots out-of-the-box -->
    <!-- without needing pre-installed VirtIO storage drivers)             -->
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='${disk_path}'/>
      <target dev='sda' bus='sata'/>
      <boot order='2'/>
    </disk>

    <!-- STAGE 2 (AFTER installing VirtIO drivers inside Windows):         -->
    <!-- Replace the disk block above with 'virtio' bus for max NVMe speed:-->
    <!--
    <disk type='block' device='disk'>
      <driver name='qemu' type='raw' cache='none' io='native' discard='unmap'/>
      <source dev='${disk_path}'/>
      <target dev='vda' bus='virtio'/>
      <boot order='2'/>
    </disk>
    -->
EOF
}

generate_full_libvirt_guide() {
    local shm_size="${1:-64}"
    shift
    local pci_list=("$@")
    local win_disk="/dev/disk/by-id/nvme-Micron_MTFDKBA1T0TFH_22043449645A"

    cat <<EOF
================================================================================
 TUNED LIBVIRT XML GUIDE (i7-11800H + RTX 3080 + 1TB NVMe + LOOKING GLASS)
================================================================================

To apply these settings to your VM, run:
  virsh edit <vm_name>

--------------------------------------------------------------------------------
1. CPU TOPOLOGY & PINNING (Insert directly under <domain type='kvm'>):
--------------------------------------------------------------------------------
$(generate_optimized_cpu_tuning_xml)

--------------------------------------------------------------------------------
2. MEMORY TUNING (16 GB with page locking, under <domain>):
--------------------------------------------------------------------------------
  <memory unit='KiB'>16777216</memory>
  <currentMemory unit='KiB'>16777216</currentMemory>
  <memoryBacking>
    <nosharepages/>
    <locked/>
  </memoryBacking>

--------------------------------------------------------------------------------
3. HYPER-V & KVM COMPATIBILITY (Replace or merge inside <features>):
--------------------------------------------------------------------------------
$(generate_hyperv_features_xml)

--------------------------------------------------------------------------------
4. LOOKING GLASS & GPU PASSTHROUGH (Inside <devices> ... </devices>):
--------------------------------------------------------------------------------
$(generate_ivshmem_xml "$shm_size")

EOF

    for pci in "${pci_list[@]}"; do
        generate_hostdev_pci_xml "$pci"
        echo ""
    done

    cat <<EOF
--------------------------------------------------------------------------------
5. 1TB PHYSICAL WINDOWS DISK PASSTHROUGH (Inside <devices> ... </devices>):
--------------------------------------------------------------------------------
$(generate_physical_disk_xml "$win_disk")

================================================================================
EOF
}
