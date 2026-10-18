#!/usr/bin/env bash
# ==============================================================================
# VFIO Passthrough + Looking Glass Setup Toolkit
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

RESOLUTION="$(detect_display_resolution)"
MANUAL_GPU=""
DRY_RUN=0
AUTO_CONFIRM=0
ACTION=""

show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

A comprehensive automation tool for VFIO GPU Passthrough and Looking Glass.

Options:
  -c, --check             Run non-destructive hardware, IOMMU, and GPU audit
  -d, --dry-run           Simulate configuration changes without writing files
  -a, --apply             Apply full host configuration (modprobe, grub, tmpfiles)
  --mode-vm, --isolate    Enable VFIO GPU isolation for Windows VM (reboot required)
  --mode-host, --restore  Restore GPU to Linux host for Blender/CUDA (reboot required)
  --status                Display live GPU driver, IOMMU, and VM status
  -x, --generate-xml      Output Libvirt XML configuration snippets for your VM
  -s, --setup-shm         Setup Looking Glass shared memory (/dev/shm/looking-glass)
  -i, --install-cli       Install CLI commands to PATH (~/.local/bin or /usr/local/bin)
  -r, --resolution <RES>  Target resolution: 1080p, 1440p, 1600p, 2560x1600 (default), 4k, or WxH
  -g, --gpu <PCI_ID>      Override target GPU PCI address (e.g., 01:00.0)
  -y, --yes               Assume yes to all confirmation prompts
  -h, --help              Show this help menu

Installed Global Commands:
  vfio-ctl                Main interactive TUI and command manager
  vfio-lg                 Alias to vfio-ctl
  looking-glass-run       Direct client launcher with hardware acceleration
  vfio-xml                Generate tuned Libvirt XML directly
  win11                   Start Windows 11 VM with Looking Glass

Examples:
  vfio-ctl --status
  vfio-ctl --check
  sudo vfio-ctl --mode-vm
  sudo vfio-ctl --mode-host
  win11
EOF
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--check)
                ACTION="check"
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -a|--apply)
                ACTION="apply"
                shift
                ;;
            --mode-vm|--isolate)
                ACTION="mode_vm"
                shift
                ;;
            --mode-host|--restore)
                ACTION="mode_host"
                shift
                ;;
            --status)
                ACTION="status"
                shift
                ;;
            -x|--generate-xml)
                ACTION="xml"
                shift
                ;;
            -s|--setup-shm)
                ACTION="shm"
                shift
                ;;
            -i|--install-cli|--install-global)
                ACTION="install_cli"
                shift
                ;;
            --install-client)
                ACTION="install_client"
                shift
                ;;
            -r|--resolution)
                RESOLUTION="$2"
                shift 2
                ;;
            -g|--gpu)
                MANUAL_GPU="$2"
                shift 2
                ;;
            -y|--yes)
                AUTO_CONFIRM=1
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_err "Unknown argument: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

get_target_ids() {
    detect_cpu
    check_iommu_active
    detect_gpus

    TARGET_PCI="${MANUAL_GPU:-${SECONDARY_GPU:-$PRIMARY_GPU}}"
    if [[ -z "$TARGET_PCI" ]]; then
        log_err "Could not find a valid GPU for passthrough."
        exit 1
    fi

    find_related_devices "$TARGET_PCI"

    TARGET_VEN_DEV_IDS=()
    TARGET_PCI_LIST=()

    for rel in "${RELATED_DEVICES[@]}"; do
        IFS='|' read -r r_pid r_vdev r_desc <<< "$rel"
        TARGET_VEN_DEV_IDS+=("$r_vdev")
        TARGET_PCI_LIST+=("$r_pid")
    done

    # Comma-separated list for vfio-pci
    DEVICE_IDS_CSV=$(IFS=,; echo "${TARGET_VEN_DEV_IDS[*]}")
}

install_cli_tools() {
    log_header "Installing VFIO + Looking Glass CLI Commands into PATH"

    # Always guarantee run-looking-glass.sh exists
    generate_launcher_script "${SCRIPT_DIR}/run-looking-glass.sh"

    local bin_dirs=()

    # User local bin
    local user_bin=""
    if [[ -n "${SUDO_USER:-}" ]]; then
        local user_home
        user_home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        user_bin="${user_home}/.local/bin"
    else
        user_bin="${HOME}/.local/bin"
    fi

    mkdir -p "$user_bin"
    bin_dirs+=("$user_bin")

    # If root, also install system-wide into /usr/local/bin
    if [[ $EUID -eq 0 ]]; then
        bin_dirs+=("/usr/local/bin")
    fi

    for target_dir in "${bin_dirs[@]}"; do
        log_step "Installing shortcuts into: ${target_dir}"
        
        # 1. vfio-ctl & vfio-lg
        ln -sf "${SCRIPT_DIR}/setup.sh" "${target_dir}/vfio-ctl"
        ln -sf "${SCRIPT_DIR}/setup.sh" "${target_dir}/vfio-lg"
        
        # 2. looking-glass-run
        ln -sf "${SCRIPT_DIR}/run-looking-glass.sh" "${target_dir}/looking-glass-run"

        # 3. vfio-launch
        ln -sf "${SCRIPT_DIR}/vfio-launch" "${target_dir}/vfio-launch"

        # 4. vfio-install-client
        ln -sf "${SCRIPT_DIR}/install-client.sh" "${target_dir}/vfio-install-client"

        # 5. vfio-setup-vm
        ln -sf "${SCRIPT_DIR}/setup-windows-vm.sh" "${target_dir}/vfio-setup-vm"

        # 6. vfio-xml helper
        cat <<EOF > "${target_dir}/vfio-xml"
#!/usr/bin/env bash
exec "${SCRIPT_DIR}/setup.sh" --generate-xml "\$@"
EOF
        chmod +x "${target_dir}/vfio-xml"

        # Fix ownership if created by sudo in user dir
        if [[ -n "${SUDO_USER:-}" && "$target_dir" == "$user_bin" ]]; then
            chown -R "${SUDO_USER}:" "$user_bin"
        fi

        log_success "Created commands: vfio-ctl, vfio-lg, looking-glass-run, vfio-launch, vfio-install-client, vfio-xml in ${target_dir}"
    done

    log_info "Verifying command availability..."
    if command -v vfio-ctl >/dev/null 2>&1; then
        log_success "All VFIO commands are now accessible directly from any terminal!"
    else
        log_warn "'${user_bin}' may need to be added to PATH in your ~/.bashrc or shell profile."
    fi
}

install_libvirt_hooks() {
    require_root
    log_header "Installing Automated Libvirt Hooks & Udev Disk Safety Rules"

    # 1. Libvirt QEMU Hook
    local hooks_dir="/etc/libvirt/hooks"
    mkdir -p "$hooks_dir"
    cp -p "${SCRIPT_DIR}/hooks/qemu" "${hooks_dir}/qemu"
    chmod +x "${hooks_dir}/qemu"
    log_success "Installed automated hook to ${hooks_dir}/qemu"

    # 2. Udev Rule to prevent auto-mounting Windows 1TB drive
    local udev_rule="/etc/udev/rules.d/99-nvme0n1-noautomount.rules"
    cat <<'EOF' > "$udev_rule"
# Prevent Linux host desktop from automounting Windows 11 NVMe drive
KERNEL=="nvme0n1*", ENV{UDISKS_IGNORE}="1"
EOF
    udevadm control --reload-rules && udevadm trigger || true
    log_success "Installed udev rule: ${udev_rule} (Auto-mount prevention active)"
}

do_apply() {
    require_root
    get_target_ids

    log_header "Applying VFIO + Looking Glass Host Configuration"
    log_info "Target GPU: ${COLOR_BOLD}${TARGET_PCI}${COLOR_RESET}"
    log_info "Vendor:Device IDs: ${COLOR_BOLD}${DEVICE_IDS_CSV}${COLOR_RESET}"
    log_info "IOMMU Boot Parameter: ${COLOR_BOLD}${CPU_IOMMU_PARAM}${COLOR_RESET}"

    if ! confirm "Proceed with writing modprobe, GRUB, and shared memory configurations?" "Y"; then
        log_warn "Operation cancelled by user."
        exit 0
    fi

    # 1. Modprobe vfio.conf
    configure_vfio_modprobe "$DEVICE_IDS_CSV"

    # 2. Initramfs modules
    configure_initramfs_modules

    # 3. GRUB kernel cmdline
    configure_grub_cmdline "$CPU_IOMMU_PARAM"

    # 4. Looking Glass shared memory
    local user_for_shm="${SUDO_USER:-$USER}"
    setup_looking_glass_shm "$user_for_shm"

    # 5. Update Bootloader & Initramfs
    update_system_boot

    # 6. Generate client launcher & install CLI tools
    install_cli_tools

    log_header "VFIO + Looking Glass Configuration Complete!"
    log_success "Host configuration files updated."
    log_info "Next Steps:"
    log_info "  1. Reboot your host system to bind the GPU to vfio-pci."
    log_info "  2. After reboot, run 'vfio-ctl --check' to verify drivers."
    log_info "  3. Configure your Libvirt VM using: 'vfio-xml'"
    log_info "  4. Launch Looking Glass from any terminal: 'looking-glass-run'"
}

do_xml() {
    get_target_ids
    local shm_size
    shm_size=$(calculate_ivshmem_size "$RESOLUTION")
    log_info "Calculated IVSHMEM size for ${RESOLUTION}: ${COLOR_BOLD}${shm_size} MB${COLOR_RESET}"
    generate_full_libvirt_guide "$shm_size" "${TARGET_PCI_LIST[@]}"
}

do_interactive_menu() {
    while true; do
        clear
        printf "${COLOR_CYAN}${COLOR_BOLD}"
        cat <<'EOF'
  _    _ _____ _____ ____    _       ____ 
 | |  | |  ___|_   _/ __ \  | |     / ___|
 | |  | | |_    | || |  | | | |    | |  _ 
  \ \/ /|  _|   | || |  | | | |___ | |_| |
   \__/ |_|    |___|\____/  |_____(_)____|
  Looking Glass + VFIO Automated Setup Toolkit
EOF
        printf "${COLOR_RESET}\n"
        printf " Detected Display: ${COLOR_GREEN}%s${COLOR_RESET} | Target Res: ${COLOR_YELLOW}%s${COLOR_RESET} | Dry Run: ${COLOR_YELLOW}%s${COLOR_RESET}\n\n" \
            "$(detect_display_resolution)" "$RESOLUTION" "$([[ $DRY_RUN -eq 1 ]] && echo 'ON' || echo 'OFF')"

        printf "  1) Run System & IOMMU Diagnostic Audit\n"
        printf "  2) Display Live GPU, Driver & VM Status\n"
        printf "  3) Switch GPU to VM Mode (Isolate for Windows 11)\n"
        printf "  4) Switch GPU to Host Mode (Restore for Linux/CUDA)\n"
        printf "  5) Generate Tuned Libvirt VM XML Configuration\n"
        printf "  6) Configure Looking Glass Shared Memory (/dev/shm)\n"
        printf "  7) Apply Full Host Setup (Modprobe, GRUB, Initramfs)\n"
        printf "  8) Install CLI Commands to PATH (win11, vfio-ctl, looking-glass-run)\n"
        printf "  9) View Windows Guest Setup Instructions\n"
        printf " 10) Toggle Dry-Run Mode\n"
        printf "  0) Exit\n\n"

        read -r -p "Select an option [0-10]: " menu_choice
        case "$menu_choice" in
            1)
                run_system_audit
                read -r -p "Press [Enter] to continue..."
                ;;
            2)
                show_gpu_mode_status
                read -r -p "Press [Enter] to continue..."
                ;;
            3)
                if [[ $EUID -ne 0 ]]; then
                    sudo bash "$0" --mode-vm
                else
                    enable_vfio_mode
                fi
                read -r -p "Press [Enter] to continue..."
                ;;
            4)
                if [[ $EUID -ne 0 ]]; then
                    sudo bash "$0" --mode-host
                else
                    disable_vfio_mode
                fi
                read -r -p "Press [Enter] to continue..."
                ;;
            5)
                read -r -p "Enter target resolution [${RESOLUTION}]: " input_res
                RESOLUTION="${input_res:-$RESOLUTION}"
                do_xml
                read -r -p "Press [Enter] to continue..."
                ;;
            6)
                if [[ $EUID -ne 0 ]]; then
                    log_warn "Root privileges required. Re-running with sudo..."
                    sudo bash "$0" --setup-shm
                else
                    setup_looking_glass_shm "${SUDO_USER:-$USER}"
                fi
                read -r -p "Press [Enter] to continue..."
                ;;
            7)
                if [[ $EUID -ne 0 ]]; then
                    log_warn "Root privileges required. Re-running with sudo..."
                    sudo bash "$0" --apply "$([[ $DRY_RUN -eq 1 ]] && echo '--dry-run')"
                else
                    do_apply
                fi
                read -r -p "Press [Enter] to continue..."
                ;;
            8)
                install_cli_tools
                read -r -p "Press [Enter] to continue..."
                ;;
            9)
                if [[ -f "${SCRIPT_DIR}/docs/GUEST_SETUP.md" ]]; then
                    cat "${SCRIPT_DIR}/docs/GUEST_SETUP.md"
                else
                    log_err "Guest setup guide not found."
                fi
                read -r -p "Press [Enter] to continue..."
                ;;
            10)
                if [[ $DRY_RUN -eq 1 ]]; then
                    DRY_RUN=0
                    log_info "Dry-run mode disabled."
                else
                    DRY_RUN=1
                    log_info "Dry-run mode enabled."
                fi
                sleep 1
                ;;
            0)
                log_info "Exiting."
                exit 0
                ;;
            *)
                log_err "Invalid selection."
                sleep 1
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"

    case "$ACTION" in
        check)
            run_system_audit
            ;;
        xml)
            do_xml
            ;;
        shm)
            require_root
            setup_looking_glass_shm "${SUDO_USER:-$USER}"
            ;;
        install_cli)
            install_cli_tools
            ;;
        install_client)
            bash "${SCRIPT_DIR}/install-client.sh"
            ;;
        apply)
            do_apply
            ;;
        mode_vm)
            enable_vfio_mode
            ;;
        mode_host)
            disable_vfio_mode
            ;;
        status)
            show_gpu_mode_status
            ;;
        *)
            if [[ -t 0 ]]; then
                do_interactive_menu
            else
                show_usage
            fi
            ;;
    esac
}

main "$@"
