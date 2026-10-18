#!/usr/bin/env bash
# ==============================================================================
# setup-windows-vm.sh - Automated KVM/Libvirt & Windows 11 VM Setup
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/detect.sh"

log_header "Automated Windows 11 KVM / VFIO Setup"

# 1. Install KVM, Libvirt, OVMF, and TPM Packages
PACKAGES=(
    qemu-system-x86
    libvirt-daemon-system
    libvirt-clients
    ovmf
    swtpm
    swtpm-tools
    virt-manager
    bridge-utils
)

MISSING=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING+=("$pkg")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    log_step "Installing KVM / Libvirt virtualization packages: ${MISSING[*]}"
    sudo apt update
    sudo apt install -y "${MISSING[@]}"
    log_success "Virtualization packages installed."
else
    log_success "All virtualization packages are already installed."
fi

# 2. Enable and Start Libvirt Services
log_step "Enabling and Starting Libvirt daemon..."
sudo systemctl enable --now libvirtd
sudo systemctl enable --now virtlogd

# Add current user to libvirt and kvm groups
sudo usermod -aG libvirt,kvm "${USER}"
log_success "User '${USER}' added to libvirt and kvm groups."

# 3. Start Default Virtual Network (for internet access)
log_step "Configuring default NAT network..."
sudo virsh net-autostart default 2>/dev/null || true
sudo virsh net-start default 2>/dev/null || true

# 4. Install Libvirt Hook (Pre-flight disk safety & CPU governor)
log_step "Installing Libvirt QEMU hook for automated safety..."
sudo mkdir -p /etc/libvirt/hooks
sudo cp -p "${SCRIPT_DIR}/hooks/qemu" /etc/libvirt/hooks/qemu
sudo chmod +x /etc/libvirt/hooks/qemu
log_success "Libvirt hook installed to /etc/libvirt/hooks/qemu."

# 5. Define Windows 11 VM in Libvirt
log_step "Defining 'win11' Virtual Machine in Libvirt..."
XML_FILE="${SCRIPT_DIR}/win11-vfio.xml"
if sudo virsh dominfo win11 >/dev/null 2>&1; then
    log_info "'win11' domain already exists in Libvirt. Updating definition..."
    sudo virsh define "$XML_FILE"
else
    sudo virsh define "$XML_FILE"
    log_success "'win11' virtual machine defined successfully!"
fi

# 6. Check GPU binding status
detect_gpus
log_step "Verifying GPU Passthrough Status..."
local_gpu_driver=""
if [[ -d "/sys/bus/pci/devices/0000:01:00.0/driver" ]]; then
    local_gpu_driver=$(basename "$(readlink /sys/bus/pci/devices/0000:01:00.0/driver)")
fi

log_info "Target RTX 3080 driver: ${COLOR_BOLD}${local_gpu_driver:-none}${COLOR_RESET}"

if [[ "$local_gpu_driver" != "vfio-pci" ]]; then
    log_warn "The NVIDIA RTX 3080 is currently bound to '${local_gpu_driver}'."
    log_info "To bind it to vfio-pci at boot, ensure you have applied host setup:"
    log_info "  sudo vfio-ctl --apply"
    log_warn "A system reboot is required for vfio-pci to take ownership of the GPU before launching!"
else
    log_success "GPU is cleanly bound to vfio-pci. Ready to run!"
    log_step "Starting Windows 11..."
    sudo virsh start win11
    log_success "Windows 11 VM is now RUNNING!"
    log_info "Launch Looking Glass anytime with: looking-glass-run"
fi
