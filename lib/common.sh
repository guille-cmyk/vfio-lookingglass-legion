#!/usr/bin/env bash
# lib/common.sh - Shared utility functions, styling, and safety helpers

# Color styling
if [[ -t 1 ]]; then
    COLOR_RED=$'\e[0;31m'
    COLOR_GREEN=$'\e[0;32m'
    COLOR_YELLOW=$'\e[1;33m'
    COLOR_BLUE=$'\e[0;34m'
    COLOR_MAGENTA=$'\e[0;35m'
    COLOR_CYAN=$'\e[0;36m'
    COLOR_BOLD=$'\e[1m'
    COLOR_RESET=$'\e[0m'
else
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_MAGENTA=''
    COLOR_CYAN=''
    COLOR_BOLD=''
    COLOR_RESET=''
fi

BACKUP_DIR="/var/backups/vfio-setup"

log_info() {
    printf "${COLOR_BLUE}[INFO]${COLOR_RESET} %s\n" "$*"
}

log_success() {
    printf "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} %s\n" "$*"
}

log_warn() {
    printf "${COLOR_YELLOW}[WARN]${COLOR_RESET} %s\n" "$*"
}

log_err() {
    printf "${COLOR_RED}[ERROR]${COLOR_RESET} %s\n" "$*" >&2
}

log_step() {
    printf "\n${COLOR_CYAN}${COLOR_BOLD}==> %s${COLOR_RESET}\n" "$*"
}

log_header() {
    printf "\n${COLOR_MAGENTA}${COLOR_BOLD}======================================================${COLOR_RESET}\n"
    printf "${COLOR_MAGENTA}${COLOR_BOLD} %s${COLOR_RESET}\n" "$*"
    printf "${COLOR_MAGENTA}${COLOR_BOLD}======================================================${COLOR_RESET}\n\n"
}

# Require sudo/root privileges
require_root() {
    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "[DRY-RUN] Root requirement bypassed for simulation."
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        log_err "This action requires root privileges. Please re-run with sudo or as root."
        exit 1
    fi
}

# Prompt confirmation (y/N)
confirm() {
    local prompt="${1:-Continue?}"
    local default="${2:-N}"

    if [[ "${AUTO_CONFIRM:-0}" -eq 1 ]]; then
        return 0
    fi

    local choice
    if [[ "$default" =~ ^[Yy]$ ]]; then
        read -r -p "$prompt [Y/n]: " choice
        choice="${choice:-Y}"
    else
        read -r -p "$prompt [y/N]: " choice
        choice="${choice:-N}"
    fi

    [[ "$choice" =~ ^[Yy]$ ]]
}

# Create timestamped backup of a file
backup_file() {
    local target_file="$1"
    if [[ ! -f "$target_file" ]]; then
        return 0
    fi

    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local backup_name
    backup_name="$(basename "$target_file").bak.${timestamp}"

    local sudo_cmd=""
    if [[ $EUID -ne 0 ]]; then
        local target_dir
        target_dir="$(dirname "$target_file")"
        if [[ ! -w "$target_dir" ]] || [[ ! -w "$target_file" ]]; then
            sudo_cmd="sudo"
        fi
    fi

    if $sudo_cmd mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        local backup_path="${BACKUP_DIR}/${backup_name}"
        $sudo_cmd cp -p "$target_file" "$backup_path"
        log_info "Backup created: ${backup_path}"
    else
        local local_backup="${target_file}.bak.${timestamp}"
        $sudo_cmd cp -p "$target_file" "$local_backup"
        log_info "Backup created: ${local_backup}"
    fi
}

# Safe write helper supporting dry run
safe_write() {
    local content="$1"
    local dest_file="$2"

    if [[ "${DRY_RUN:-0}" -eq 1 ]]; then
        log_info "[DRY-RUN] Target: ${dest_file}"
        printf "${COLOR_CYAN}--- BEGIN CONTENT ---${COLOR_RESET}\n"
        printf "%s\n" "$content"
        printf "${COLOR_CYAN}--- END CONTENT ---${COLOR_RESET}\n"
        return 0
    fi

    backup_file "$dest_file"
    local dir
    dir="$(dirname "$dest_file")"

    local sudo_cmd=""
    if [[ $EUID -ne 0 ]]; then
        if [[ ! -w "$dir" ]] || ([[ -e "$dest_file" ]] && [[ ! -w "$dest_file" ]]); then
            sudo_cmd="sudo"
        fi
    fi

    if [[ ! -d "$dir" ]]; then
        $sudo_cmd mkdir -p "$dir"
    fi

    if [[ -n "$sudo_cmd" ]]; then
        printf "%s\n" "$content" | sudo tee "$dest_file" >/dev/null
    else
        printf "%s\n" "$content" > "$dest_file"
    fi
    log_success "Wrote configuration to: ${dest_file}"
}

