#!/usr/bin/env bash
# lib/preflight.sh - Pre-launch safety verification and performance optimization

# 1. Ensure 1TB Windows disk is safe (unmounted)
ensure_disk_safety() {
    local target_disk="${1:-/dev/nvme0n1}"
    log_step "Pre-Flight: Checking Physical Disk Safety"

    local mounted_parts=()
    while IFS= read -r part; do
        if [[ -n "$part" ]]; then
            mounted_parts+=("$part")
        fi
    done < <(lsblk -rno NAME,MOUNTPOINTS "$target_disk" 2>/dev/null | awk '$2 != "" {print $1}')

    if [[ ${#mounted_parts[@]} -gt 0 ]]; then
        log_warn "Target disk ${target_disk} has active mounts on Linux host:"
        for p in "${mounted_parts[@]}"; do
            printf "    - /dev/%s\n" "$p"
        done
        log_info "Attempting safe unmount to prevent filesystem corruption..."

        for p in "${mounted_parts[@]}"; do
            sync
            if sudo umount "/dev/$p" 2>/dev/null; then
                log_success "Unmounted /dev/$p successfully."
            else
                log_err "Failed to unmount /dev/$p. It may be in use by an active process."
                log_err "Aborting VM launch to protect NTFS filesystem integrity!"
                return 1
            fi
        done
    else
        log_success "Physical disk ${target_disk} is clean and safely unmounted."
    fi
    return 0
}

# 2. Ensure Looking Glass Shared Memory exists with proper permissions and size
ensure_shm_safety() {
    local shm_file="/dev/shm/looking-glass"
    local target_user="${SUDO_USER:-$USER}"
    log_step "Pre-Flight: Checking Looking Glass Shared Memory"

    local current_size
    current_size=$(stat -c %s "$shm_file" 2>/dev/null || echo 0)
    local current_owner
    current_owner=$(stat -c %U "$shm_file" 2>/dev/null || echo "")

    if [[ ! -e "$shm_file" || "$current_size" -lt 33554432 || "$current_owner" != "$target_user" ]]; then
        log_info "${shm_file} is missing or undersized (size: ${current_size} bytes). Allocating 64MB..."

        # If existing file is owned by another user (e.g. root), remove it to avoid fs.protected_regular EACCES
        if [[ -e "$shm_file" && "$current_owner" != "$target_user" ]]; then
            if [[ $EUID -eq 0 ]]; then
                rm -f "$shm_file"
            else
                sudo rm -f "$shm_file"
            fi
        fi

        # Create directly as target_user so owner is unprivileged user
        if [[ $EUID -eq 0 && "$target_user" != "root" ]]; then
            su - "$target_user" -c "touch '$shm_file' && truncate -s 64M '$shm_file' && chmod 0660 '$shm_file'" 2>/dev/null || {
                touch "$shm_file"
                truncate -s 64M "$shm_file"
                chown "${target_user}:kvm" "$shm_file" 2>/dev/null || chown "${target_user}" "$shm_file"
                chmod 0660 "$shm_file"
            }
        else
            touch "$shm_file"
            truncate -s 64M "$shm_file"
            chgrp kvm "$shm_file" 2>/dev/null || sudo chown "${target_user}:kvm" "$shm_file" 2>/dev/null || true
            chmod 0660 "$shm_file" 2>/dev/null || sudo chmod 0660 "$shm_file"
        fi
        log_success "Allocated 64MB with 0660 permissions on ${shm_file}."
    else
        # Verify read/write permissions
        if [[ ! -r "$shm_file" || ! -w "$shm_file" ]]; then
            log_warn "Permissions on ${shm_file} are incorrect. Fixing..."
            chmod 0660 "$shm_file" 2>/dev/null || sudo chmod 0660 "$shm_file"
        fi
        log_success "Shared memory ${shm_file} is verified (64MB, accessible)."
    fi
}

# 3. Ensure GPU is bound to vfio-pci
ensure_gpu_vfio_bound() {
    local gpu_pci="${1:-0000:01:00.0}"
    log_step "Pre-Flight: Verifying GPU Driver Binding"

    local driver_path="/sys/bus/pci/devices/${gpu_pci}/driver"
    if [[ -L "$driver_path" ]]; then
        local driver_name
        driver_name=$(basename "$(readlink "$driver_path")")
        if [[ "$driver_name" == "vfio-pci" ]]; then
            log_success "GPU ${gpu_pci} is securely bound to vfio-pci."
            return 0
        else
            log_warn "GPU ${gpu_pci} is currently bound to '${driver_name}' (expected: vfio-pci)."
            log_info "Attempting to unbind from ${driver_name} and rebind to vfio-pci..."
            if sudo bash -c "echo '${gpu_pci#0000:}' > /sys/bus/pci/drivers/${driver_name}/unbind && echo '${gpu_pci#0000:}' > /sys/bus/pci/drivers/vfio-pci/bind" 2>/dev/null; then
                log_success "Successfully rebound GPU to vfio-pci."
                return 0
            else
                log_warn "Could not rebind GPU automatically. Host reboot may be needed."
            fi
        fi
    else
        log_warn "GPU ${gpu_pci} has no active kernel driver attached."
    fi
}

# 4. Set CPU Governor (powersave <-> performance)
set_cpu_governor() {
    local target_gov="$1" # 'performance' or 'powersave'
    log_step "Tuning: Setting CPU Governor to '${target_gov}'"

    local gov_files=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
    if [[ ${#gov_files[@]} -gt 0 && -f "${gov_files[0]}" ]]; then
        if sudo bash -c "for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo '${target_gov}' > \"\$f\"; done" 2>/dev/null; then
            log_success "All CPU cores switched to '${target_gov}' governor."
        else
            log_warn "Could not switch CPU governor (sudo permission required)."
        fi
    fi
}

# 5. Compact memory to eliminate fragmentation for 16GB allocation
compact_host_memory() {
    log_step "Tuning: Compacting Host RAM"
    if [[ -f "/proc/sys/vm/compact_memory" ]]; then
        sudo bash -c "echo 1 > /proc/sys/vm/compact_memory" 2>/dev/null || true
        log_success "Host memory compacted for clean 16GB VM reservation."
    fi
}
