#!/usr/bin/env bash
# ==============================================================================
# run.sh (win11) - The One-Command VFIO Passthrough + Looking Glass Launcher
# Automatically installs, configures, tunes, and launches everything.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# Source submodules
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/detect.sh"
source "${SCRIPT_DIR}/lib/vfio_config.sh"
source "${SCRIPT_DIR}/lib/looking_glass.sh"
source "${SCRIPT_DIR}/lib/libvirt_gen.sh"
source "${SCRIPT_DIR}/lib/client_helper.sh"
source "${SCRIPT_DIR}/lib/preflight.sh"
source "${SCRIPT_DIR}/lib/boot_disk.sh"

VM_NAME="win11"
SHM_FILE="/dev/shm/looking-glass"

virsh_cmd() {
    virsh -c qemu:///system "$@"
}

cleanup_session() {
    log_header "Session Finished"
    set_cpu_governor "powersave"
    if [[ -n "${VM_NAME:-}" ]]; then
        local st
        st=$(virsh_cmd domstate "$VM_NAME" 2>/dev/null || echo "shut off")
        if [[ "$st" == "running" ]]; then
            if confirm "Would you like to power off the '${VM_NAME}' virtual machine?" "Y"; then
                log_info "Stopping '${VM_NAME}'..."
                virsh_cmd destroy "$VM_NAME" 2>/dev/null || true
                log_success "'${VM_NAME}' stopped."
            else
                log_info "Leaving '${VM_NAME}' running in background."
            fi
        fi
    fi
}
trap cleanup_session EXIT INT TERM

# ==============================================================================
# STAGE 1: Automated Dependency & System Provisioning
# ==============================================================================
ensure_all_installed_and_configured() {
    log_step "Checking System Virtualization & Looking Glass Components"
    local needs_refresh=0

    # 1. Virtualization & Compiler Packages
    local required_pkgs=(
        qemu-system-x86
        libvirt-daemon-system
        libvirt-clients
        ovmf
        swtpm
        swtpm-tools
        virt-manager
        bridge-utils
        cmake
        ninja-build
        binutils-dev
        libspice-protocol-dev
        libxpresent-dev
        libdecor-0-dev
        dosfstools
        python3-hivex
    )

    local missing_pkgs=()
    for pkg in "${required_pkgs[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            missing_pkgs+=("$pkg")
        fi
    done

    if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
        log_info "Installing missing dependencies: ${missing_pkgs[*]}"
        sudo apt update
        sudo apt install -y "${missing_pkgs[@]}"
        needs_refresh=1
    fi

    # 2. Looking Glass Client Binary
    if ! command -v looking-glass-client >/dev/null 2>&1; then
        log_info "looking-glass-client not found. Building and installing now..."
        bash "${SCRIPT_DIR}/install-client.sh"
    fi

    # 3. Libvirt Services & Group Membership
    if ! systemctl is-active --quiet libvirtd; then
        log_info "Starting libvirtd service..."
        sudo systemctl enable --now libvirtd virtlogd
        sudo virsh net-autostart default 2>/dev/null || true
        sudo virsh net-start default 2>/dev/null || true
    fi

    for grp in libvirt kvm; do
        if ! id -nG "$USER" | grep -qw "$grp"; then
            sudo usermod -aG "$grp" "$USER"
            log_info "Added '$USER' to group '$grp'."
        fi
    done

    # 4. Anti-Corruption Udev Rule for 1TB NVMe
    local udev_rule="/etc/udev/rules.d/99-nvme0n1-noautomount.rules"
    if [[ ! -f "$udev_rule" ]]; then
        log_info "Installing anti-corruption udev rule for 1TB NVMe drive..."
        sudo bash -c 'cat <<EOF > /etc/udev/rules.d/99-nvme0n1-noautomount.rules
KERNEL=="nvme0n1*", ENV{UDISKS_IGNORE}="1"
EOF'
        sudo udevadm control --reload-rules && sudo udevadm trigger || true
    fi

    # 5. Hypervisor Hook (/etc/libvirt/hooks/qemu)
    local hook_dest="/etc/libvirt/hooks/qemu"
    if [[ ! -f "$hook_dest" ]]; then
        log_info "Installing automated libvirt safety hook..."
        sudo mkdir -p /etc/libvirt/hooks
        sudo cp -p "${SCRIPT_DIR}/hooks/qemu" "$hook_dest"
        sudo chmod +x "$hook_dest"
    fi

    # 6. Sized Shared Memory (64MB)
    ensure_shm_safety

    # 7. Define VM in Libvirt
    if command -v virsh >/dev/null 2>&1; then
        virsh_cmd define "${SCRIPT_DIR}/win11-vfio.xml" >/dev/null 2>&1 || true
    fi

    # 8. Check host VFIO configuration status
    local vfio_conf="/etc/modprobe.d/vfio.conf"
    if [[ ! -s "$vfio_conf" && ! -s "/etc/modprobe.d/vfio.conf.disabled" ]]; then
        log_info "Note: Host VFIO early-binding configuration is not yet applied."
        log_info "To configure persistent GPU isolation, run: sudo vfio-ctl --apply"
    fi
}

# ==============================================================================
# STAGE 2: Hardware Driver Check (Reboot required check)
# ==============================================================================
check_gpu_driver_ready() {
    local gpu_driver=""
    if [[ -d "/sys/bus/pci/devices/0000:01:00.0/driver" ]]; then
        gpu_driver=$(basename "$(readlink /sys/bus/pci/devices/0000:01:00.0/driver)")
    fi

    if [[ "$gpu_driver" != "vfio-pci" ]]; then
        log_header "GPU Driver Status: Host Mode (${gpu_driver:-none})"
        log_warn "Your NVIDIA RTX 3080 is currently bound to: '${gpu_driver:-none}'."
        
        if [[ -f "/etc/modprobe.d/vfio.conf" ]]; then
            log_info "VFIO configuration is in place, but a system reboot is needed to load vfio-pci."
            if confirm "Reboot system now to bind RTX 3080 to VFIO?" "N"; then
                sudo reboot
                exit 0
            fi
        else
            log_info "To dedicate the NVIDIA RTX 3080 to Windows 11 with full performance:"
            log_info "  1. Run:  sudo vfio-ctl --mode-vm"
            log_info "  2. Reboot your laptop, then run: win11"
        fi

        printf "\n"
        if ! confirm "Would you like to start Windows 11 in standard SPICE display mode anyway?" "Y"; then
            log_info "Exiting. Run 'win11' when you are ready."
            exit 0
        fi
        log_info "Proceeding with VM launch (SPICE console mode)..."
    else
        log_success "GPU is cleanly bound to vfio-pci. Direct hardware acceleration enabled!"
    fi
}

# ==============================================================================
# STAGE 3: Pre-flight Safety, VM Boot & Looking Glass Launch
# ==============================================================================
launch_vm_and_looking_glass() {
    local target_disk="/dev/nvme0n1"
    local has_efi=0
    if lsblk -rno FSTYPE "$target_disk" 2>/dev/null | grep -qE "vfat|fat32"; then
        has_efi=1
    fi

    if [[ $has_efi -eq 0 ]]; then
        log_header "Windows 11 Pro Installation Mode"
        log_info "No EFI System Partition detected on ${target_disk}."
        log_info "Starting VM with Windows 11 25H2 Installer & LG Tools attached."
        log_info "------------------------------------------------------------------"
        log_info "SETUP GUIDE:"
        log_info "  1. The installer console will open in virt-manager."
        log_info "  2. Select 'Windows 11 Pro' and accept terms."
        log_info "  3. Choose 'Custom: Install Windows only (advanced)'."
        log_info "  4. Select the 1TB Micron NVMe drive (Drive 0) and click Next."
        log_info "  5. Windows will automatically format and partition the drive."
        log_info "  6. When installation reboots into desktop, open Drive D: (LG_TOOLS)"
        log_info "     and run 'looking-glass-host-setup.exe'."
        log_info "------------------------------------------------------------------"
    else
        log_header "Launching Windows 11 with Looking Glass"
    fi

    # 1. Ensure 1TB NVMe is safe and unmounted
    if ! ensure_disk_safety "$target_disk"; then
        log_err "Aborting launch: 1TB disk could not be safely unmounted."
        exit 1
    fi

    # 2. Performance: Set CPU Governor to performance
    set_cpu_governor "performance"

    # 3. Performance: Compact memory
    compact_host_memory

    # 4. Start or Restart VM to apply latest hardware/firmware configuration
    local state
    state=$(virsh_cmd domstate "$VM_NAME" 2>/dev/null || echo "shut off")
    if [[ "$state" == "running" ]]; then
        log_warn "Virtual machine '${VM_NAME}' is currently running."
        if confirm "Restart '${VM_NAME}' with the new bootloader & XML configuration?" "Y"; then
            log_step "Stopping existing '${VM_NAME}' session..."
            virsh_cmd destroy "$VM_NAME" 2>/dev/null || true
            sleep 1
            virsh_cmd define "${SCRIPT_DIR}/win11-vfio.xml"
            log_step "Starting '${VM_NAME}' with updated configuration..."
            virsh_cmd start "$VM_NAME"
            log_success "'${VM_NAME}' started."
            sleep 2
        else
            log_info "Connecting to existing '${VM_NAME}' instance."
        fi
    else
        virsh_cmd define "${SCRIPT_DIR}/win11-vfio.xml"
        log_step "Starting '${VM_NAME}' Virtual Machine..."
        virsh_cmd start "$VM_NAME"
        log_success "'${VM_NAME}' started."
        sleep 2
    fi

    # 5. Check if user explicitly asked for graphical console or if installing
    local want_console=0
    for arg in "$@"; do
        if [[ "$arg" == "--console" || "$arg" == "-c" ]]; then
            want_console=1
            break
        fi
    done

    if [[ $has_efi -eq 0 || $want_console -eq 1 ]]; then
        log_step "Launching Graphical Console (virt-manager)..."
        exec virt-manager --connect qemu:///system --show-domain-console "$VM_NAME"
    fi

    # 6. Determine SPICE arguments (wait briefly for port 5900 to open)
    local spice_args=()
    local spice_found=0
    for ((i=1; i<=4; i++)); do
        if ss -tln 2>/dev/null | grep -q ":5900\b"; then
            spice_found=1
            break
        fi
        sleep 1
    done

    if [[ $spice_found -eq 1 ]]; then
        log_info "SPICE server detected on port 5900. Enabling mouse/keyboard capture."
        spice_args+=("spice:enable=yes" "spice:port=5900")
    else
        log_info "SPICE not yet listening. Starting in display mode."
        spice_args+=("spice:enable=no")
    fi

    # 7. Launch Looking Glass Client
    log_step "Launching Looking Glass Client (Capture toggle: Right Control)..."
    log_info "Tip: Run 'win11 --console' if you need the direct SPICE display before Looking Glass Host is active."
    exec looking-glass-client -f "$SHM_FILE" -g egl "${spice_args[@]}" "$@"
}

# Main entrypoint
main() {
    ensure_all_installed_and_configured
    check_gpu_driver_ready
    launch_vm_and_looking_glass "$@"
}

main "$@"
