#!/usr/bin/env bash
# lib/detect.sh - Hardware, CPU, GPU, and IOMMU Group detection

detect_cpu() {
    CPU_VENDOR=""
    CPU_IOMMU_PARAM=""
    CPU_HAS_VIRT=0

    if grep -q "vmx" /proc/cpuinfo; then
        CPU_VENDOR="Intel"
        CPU_IOMMU_PARAM="intel_iommu=on iommu=pt"
        CPU_HAS_VIRT=1
    elif grep -q "svm" /proc/cpuinfo; then
        CPU_VENDOR="AMD"
        CPU_IOMMU_PARAM="amd_iommu=on iommu=pt"
        CPU_HAS_VIRT=1
    fi
}

check_iommu_active() {
    IOMMU_ACTIVE=0
    if [[ -d "/sys/kernel/iommu_groups" ]] && [[ $(ls -A /sys/kernel/iommu_groups 2>/dev/null | wc -l) -gt 0 ]]; then
        IOMMU_ACTIVE=1
    elif dmesg 2>/dev/null | grep -iE "dmar|iommu" | grep -iq "enabled"; then
        IOMMU_ACTIVE=1
    fi
}

# Enumerate GPUs and their audio controllers
detect_gpus() {
    DISCOVERED_GPUS=()
    DISCOVERED_AUDIO=()
    PRIMARY_GPU=""
    SECONDARY_GPU=""

    while IFS= read -r line; do
        local pci_id
        pci_id=$(echo "$line" | awk '{print $1}')
        local desc
        desc=$(echo "$line" | cut -d' ' -f2-)
        local ven_dev
        ven_dev=$(echo "$line" | grep -o '\[[0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\]' | tail -n1 | tr -d '[]')
        
        # Check if boot_vga
        local is_boot=0
        if [[ -f "/sys/bus/pci/devices/0000:${pci_id}/boot_vga" ]] && [[ $(cat "/sys/bus/pci/devices/0000:${pci_id}/boot_vga") -eq 1 ]]; then
            is_boot=1
            PRIMARY_GPU="$pci_id"
        fi

        DISCOVERED_GPUS+=("${pci_id}|${ven_dev}|${is_boot}|${desc}")
    done < <(lspci -nn | grep -E "VGA compatible controller|3D controller|Display controller")

    # If primary wasn't flagged by boot_vga, default to first GPU or Intel iGPU if present
    if [[ -z "$PRIMARY_GPU" && ${#DISCOVERED_GPUS[@]} -gt 0 ]]; then
        for item in "${DISCOVERED_GPUS[@]}"; do
            if echo "$item" | grep -iq "Intel"; then
                PRIMARY_GPU=$(echo "$item" | cut -d'|' -f1)
                break
            fi
        done
        if [[ -z "$PRIMARY_GPU" ]]; then
            PRIMARY_GPU=$(echo "${DISCOVERED_GPUS[0]}" | cut -d'|' -f1)
        fi
    fi

    # Detect secondary GPU
    for item in "${DISCOVERED_GPUS[@]}"; do
        local pid
        pid=$(echo "$item" | cut -d'|' -f1)
        if [[ "$pid" != "$PRIMARY_GPU" ]]; then
            SECONDARY_GPU="$pid"
            break
        fi
    done
}

# Find audio / sub-functions associated with a GPU bus
find_related_devices() {
    local target_pci="$1" # e.g. 0000:01:00.0 or 01:00.0
    local stripped_pci="${target_pci#0000:}"
    local base_bus
    base_bus=$(echo "$stripped_pci" | cut -d'.' -f1) # e.g. 01:00

    RELATED_DEVICES=()
    while IFS= read -r line; do
        local pci_id
        pci_id=$(echo "$line" | awk '{print $1}')
        local ven_dev
        ven_dev=$(echo "$line" | grep -o '\[[0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\}\]' | tail -n1 | tr -d '[]')
        local desc
        desc=$(echo "$line" | cut -d' ' -f2-)
        RELATED_DEVICES+=("${pci_id}|${ven_dev}|${desc}")
    done < <(lspci -nn | grep -E "^(0000:)?${base_bus}\.")
}

# Inspect IOMMU group of a specific PCI device
check_iommu_group() {
    local target_pci="$1"
    local full_pci="$target_pci"
    if [[ ! "$full_pci" =~ ^[0-9a-fA-F]{4}: ]]; then
        full_pci="0000:${full_pci}"
    fi
    local sys_dev_path="/sys/bus/pci/devices/${full_pci}"
    
    TARGET_IOMMU_GROUP=""
    GROUP_DEVICES=()
    GROUP_ISOLATED=1

    if [[ ! -d "$sys_dev_path/iommu_group" ]]; then
        TARGET_IOMMU_GROUP="Unknown (IOMMU not active)"
        GROUP_ISOLATED=0
        return 1
    fi

    TARGET_IOMMU_GROUP=$(basename "$(readlink "$sys_dev_path/iommu_group")")
    local group_path="/sys/kernel/iommu_groups/${TARGET_IOMMU_GROUP}/devices"

    local stripped_pci="${target_pci#0000:}"
    local base_bus
    base_bus=$(echo "$stripped_pci" | cut -d'.' -f1)

    for dev in "$group_path"/*; do
        local dev_name
        dev_name=$(basename "$dev")
        local stripped_dev="${dev_name#0000:}"
        local dev_desc
        dev_desc=$(lspci -nns "$dev_name")
        GROUP_DEVICES+=("$dev_desc")

        # Check if any device in group does NOT belong to the same base bus or PCIe switch
        local d_bus
        d_bus=$(echo "$stripped_dev" | cut -d'.' -f1)
        if [[ "$d_bus" != "$base_bus" ]]; then
            # If it's a root port or bridge, it might be an issue without ACS override
            if ! echo "$dev_desc" | grep -iE "PCI bridge|Root Port" >/dev/null; then
                GROUP_ISOLATED=0
            fi
        fi
    done
}

detect_windows_disk() {
    WIN_DISK_DEV=""
    WIN_DISK_BY_ID=""
    WIN_DISK_MOUNT=""
    WIN_DISK_SIZE=""
    WIN_DISK_HAS_ESP=0

    # Look for NTFS partition
    local ntfs_part
    ntfs_part=$(lsblk -rno NAME,FSTYPE | grep -i "ntfs" | awk '{print $1}' | head -n 1)

    if [[ -n "$ntfs_part" ]]; then
        # Get parent disk
        local parent_disk
        parent_disk=$(lsblk -rno PKNAME "/dev/${ntfs_part}" 2>/dev/null || true)
        if [[ -z "$parent_disk" ]]; then
            parent_disk=$(echo "$ntfs_part" | sed -E 's/p[0-9]+$//')
        fi

        WIN_DISK_DEV="/dev/${parent_disk}"
        WIN_DISK_SIZE=$(lsblk -rno SIZE "${WIN_DISK_DEV}" 2>/dev/null | head -n 1)
        WIN_DISK_MOUNT=$(lsblk -rno MOUNTPOINTS "/dev/${ntfs_part}" 2>/dev/null | head -n 1)

        # Find persistent by-id path
        local by_id
        by_id=$(find /dev/disk/by-id/ -lname "*${parent_disk}" ! -name "*part*" 2>/dev/null | head -n 1)
        WIN_DISK_BY_ID="${by_id:-$WIN_DISK_DEV}"

        # Check if parent disk has an EFI/FAT32 partition
        if lsblk -rno FSTYPE "${WIN_DISK_DEV}" 2>/dev/null | grep -iE "vfat|fat32" >/dev/null; then
            WIN_DISK_HAS_ESP=1
        fi
    fi
}

# Run full diagnostic summary
run_system_audit() {
    log_header "VFIO & Hardware Diagnostic Audit"

    detect_cpu
    check_iommu_active
    detect_gpus
    detect_windows_disk

    # 1. CPU Virtualization
    log_step "CPU Virtualization"
    if [[ $CPU_HAS_VIRT -eq 1 ]]; then
        log_success "CPU Vendor: ${CPU_VENDOR} with Hardware Virtualization enabled"
    else
        log_err "Hardware Virtualization (VT-x / AMD-V) is NOT detected in CPU flags!"
        log_warn "Please enable VT-x / AMD-V in your BIOS/UEFI settings."
    fi

    # 2. IOMMU Status
    log_step "Kernel IOMMU Status"
    if [[ $IOMMU_ACTIVE -eq 1 ]]; then
        log_success "IOMMU is active in kernel (IOMMU groups exist)"
    else
        log_warn "IOMMU is NOT active in the running kernel."
        log_info "Required kernel parameter: ${COLOR_BOLD}${CPU_IOMMU_PARAM}${COLOR_RESET}"
    fi

    # 3. Discovered GPUs
    log_step "Discovered Display Controllers"
    for item in "${DISCOVERED_GPUS[@]}"; do
        IFS='|' read -r pid vdev is_boot desc <<< "$item"
        local role="Secondary / Target GPU"
        if [[ "$pid" == "$PRIMARY_GPU" ]]; then
            role="Primary Host GPU"
        fi
        printf "  • ${COLOR_BOLD}%s${COLOR_RESET} [%s] (%s)\n    %s\n" "$pid" "$vdev" "$role" "$desc"
    done

    # 4. Target GPU & IOMMU Group Isolation
    log_step "Passthrough Target Isolation Analysis"
    local target="${SECONDARY_GPU:-$PRIMARY_GPU}"
    if [[ -z "$target" ]]; then
        log_err "No GPUs found on system!"
        return 1
    fi

    log_info "Selected Passthrough Target: ${target}"
    find_related_devices "$target"
    log_info "Devices associated with target PCIe slot:"
    for rel in "${RELATED_DEVICES[@]}"; do
        IFS='|' read -r r_pid r_vdev r_desc <<< "$rel"
        printf "    - %s [%s]: %s\n" "$r_pid" "$r_vdev" "$r_desc"
    done

    check_iommu_group "$target"
    log_info "IOMMU Group: ${TARGET_IOMMU_GROUP}"
    if [[ ${#GROUP_DEVICES[@]} -gt 0 ]]; then
        printf "  Devices in Group %s:\n" "${TARGET_IOMMU_GROUP}"
        for g_dev in "${GROUP_DEVICES[@]}"; do
            printf "    > %s\n" "$g_dev"
        done
    fi

    if [[ $GROUP_ISOLATED -eq 1 ]]; then
        log_success "IOMMU Group ${TARGET_IOMMU_GROUP} is cleanly isolated! Perfect candidate for VFIO."
    else
        log_warn "IOMMU Group ${TARGET_IOMMU_GROUP} shares devices with other hardware."
        log_warn "You may need the ACS Override patch if unrelated devices cannot be unbinded."
    fi

    # 5. Detected Physical Windows Storage
    log_step "Detected Physical Windows Storage (1TB NVMe)"
    if [[ -n "$WIN_DISK_DEV" ]]; then
        log_success "Discovered Windows 11 Drive: ${COLOR_BOLD}${WIN_DISK_DEV}${COLOR_RESET} (${WIN_DISK_SIZE})"
        log_info "Persistent Path: ${COLOR_BOLD}${WIN_DISK_BY_ID}${COLOR_RESET}"
        if [[ -n "$WIN_DISK_MOUNT" ]]; then
            log_warn "Drive is currently mounted on Linux at: ${WIN_DISK_MOUNT}"
            log_warn "SAFETY REQUIREMENT: MUST be unmounted before launching VM to prevent filesystem corruption!"
        else
            log_success "Drive is safely unmounted on Linux."
        fi

        if [[ $WIN_DISK_HAS_ESP -eq 1 ]]; then
            log_success "EFI System Partition detected on the drive."
        else
            log_info "Note: No FAT32 EFI partition found on ${WIN_DISK_DEV}."
            log_info "      Recommendation: Use a small virtual EFI boot disk (win11-boot.qcow2) for OVMF boot."
        fi
    else
        log_info "No separate Windows NTFS physical drive detected."
    fi
}
