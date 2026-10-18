#!/usr/bin/env bash
# lib/boot_disk.sh - Prepares and manages virtual EFI boot disk for Windows 11 VM

ensure_win11_boot_disk() {
    local boot_img="${SCRIPT_DIR}/win11-boot.qcow2"
    local target_img="/var/lib/libvirt/images/win11-boot.qcow2"

    # If already installed in libvirt images directory with valid size
    if [[ -f "$target_img" && -s "$target_img" ]]; then
        return 0
    fi

    # If local image exists, copy and set libvirt permissions
    if [[ -f "$boot_img" && -s "$boot_img" ]]; then
        log_info "Installing virtual boot disk to ${target_img}..."
        sudo cp -f "$boot_img" "$target_img"
        sudo chown libvirt-qemu:kvm "$target_img" 2>/dev/null || sudo chown root:kvm "$target_img"
        sudo chmod 0660 "$target_img"
        log_success "Boot disk installed to: ${target_img}"
        return 0
    fi

    log_step "Generating Virtual EFI Boot Disk (win11-boot.qcow2)"
    log_info "The physical 1TB disk (/dev/nvme0n1) does not contain a FAT32 EFI partition."
    log_info "Creating a safe, non-destructive virtual EFI partition to boot Windows 11..."

    # Ensure dependencies
    local missing_tools=()
    for pkg in dosfstools python3-hivex; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_tools+=("$pkg")
        fi
    done

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_info "Installing boot disk build dependencies: ${missing_tools[*]}"
        sudo apt update
        sudo apt install -y "${missing_tools[@]}"
    fi

    local raw_img="${SCRIPT_DIR}/win11-boot.raw"
    local mnt_esp="/tmp/win11_esp_mnt"
    local mnt_src="/tmp/win11_src_mnt"

    mkdir -p "$mnt_esp" "$mnt_src"
    rm -f "$raw_img"

    # Create 128MB FAT32 disk image
    truncate -s 128M "$raw_img"
    mkfs.vfat -F 32 -n "EFI" "$raw_img" >/dev/null

    sudo mount "$raw_img" "$mnt_esp"

    # Mount Windows partition read-only to extract boot files
    local win_part="/dev/nvme0n1p2"
    local has_win=0
    if sudo mount -o ro "$win_part" "$mnt_src" 2>/dev/null; then
        has_win=1
    fi

    sudo mkdir -p "${mnt_esp}/EFI/BOOT" "${mnt_esp}/EFI/Microsoft/Boot"

    if [[ $has_win -eq 1 && -f "${mnt_src}/Windows/Boot/EFI/bootmgfw.efi" ]]; then
        log_info "Extracting official Windows Boot Manager files from ${win_part}..."
        sudo cp "${mnt_src}/Windows/Boot/EFI/bootmgfw.efi" "${mnt_esp}/EFI/Microsoft/Boot/bootmgfw.efi"
        sudo cp "${mnt_src}/Windows/Boot/EFI/bootmgfw.efi" "${mnt_esp}/EFI/BOOT/BOOTX64.EFI"
        [[ -f "${mnt_src}/Windows/Boot/EFI/bootmgr.efi" ]] && sudo cp "${mnt_src}/Windows/Boot/EFI/bootmgr.efi" "${mnt_esp}/EFI/Microsoft/Boot/"
        [[ -d "${mnt_src}/Windows/Boot/EFI/en-US" ]] && sudo cp -r "${mnt_src}/Windows/Boot/EFI/en-US" "${mnt_esp}/EFI/Microsoft/Boot/"
        [[ -d "${mnt_src}/Windows/Boot/Resources" ]] && sudo cp -r "${mnt_src}/Windows/Boot/Resources" "${mnt_esp}/EFI/Microsoft/Boot/"
        [[ -d "${mnt_src}/Windows/Boot/Fonts" ]] && sudo cp -r "${mnt_src}/Windows/Boot/Fonts" "${mnt_esp}/EFI/Microsoft/Boot/"

        # Check for existing BCD
        if [[ -f "${mnt_src}/Windows/System32/Recovery/BCD" ]]; then
            log_info "Using recovery BCD template from Windows installation..."
            sudo cp "${mnt_src}/Windows/System32/Recovery/BCD" "${mnt_esp}/EFI/Microsoft/Boot/BCD"
        elif [[ -f "${mnt_src}/Boot/BCD" ]]; then
            log_info "Using existing BCD from /Boot/BCD..."
            sudo cp "${mnt_src}/Boot/BCD" "${mnt_esp}/EFI/Microsoft/Boot/BCD"
        fi
    fi

    # If BCD still not present, generate one pointing to Windows partition
    if [[ ! -f "${mnt_esp}/EFI/Microsoft/Boot/BCD" ]]; then
        log_info "Generating configured BCD pointing to Windows partition (c23b12a6-54f4-476f-9aaa-7a7f3d2de5f5)..."
        python3 "${SCRIPT_DIR}/tools/create_bcd/create_bcd.py" --output "/tmp/generated_BCD" --win-uuid "c23b12a6-54f4-476f-9aaa-7a7f3d2de5f5"
        sudo cp "/tmp/generated_BCD" "${mnt_esp}/EFI/Microsoft/Boot/BCD"
        rm -f "/tmp/generated_BCD"
    fi

    if [[ $has_win -eq 1 ]]; then
        sudo umount "$mnt_src" 2>/dev/null || true
    fi
    sudo umount "$mnt_esp" 2>/dev/null || true
    rm -rf "$mnt_esp" "$mnt_src"

    # Convert to qcow2
    log_info "Converting virtual boot disk to qcow2..."
    qemu-img convert -O qcow2 "$raw_img" "$boot_img"
    rm -f "$raw_img"

    # Install into libvirt images directory with proper qemu permissions
    sudo cp -f "$boot_img" "$target_img"
    sudo chown libvirt-qemu:kvm "$target_img" 2>/dev/null || sudo chown root:kvm "$target_img"
    sudo chmod 0660 "$target_img"
    log_success "Virtual EFI Boot Disk installed to: ${target_img}"
}
