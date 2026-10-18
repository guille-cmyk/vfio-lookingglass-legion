#!/usr/bin/env bash
# run-looking-glass.sh - Tuned Launcher with Safety Checks & Dynamic Governor
set -euo pipefail

SHM_FILE="/dev/shm/looking-glass"

# Safety: Unmount 1TB Windows disk if host mounted it
if lsblk -rno NAME,MOUNTPOINTS /dev/nvme0n1 2>/dev/null | grep -v "^$" | awk '$2 != ""' >/dev/null; then
    echo "[WARN] /dev/nvme0n1 has active mounts on Linux host. Unmounting to prevent corruption..."
    for p in $(lsblk -rno NAME,MOUNTPOINTS /dev/nvme0n1 2>/dev/null | awk '$2 != "" {print $1}'); do
        sync
        sudo umount "/dev/$p" 2>/dev/null || {
            echo "[ERROR] Could not unmount /dev/$p! Aborting to protect NTFS integrity."
            exit 1
        }
    done
    echo "[SUCCESS] /dev/nvme0n1 safely unmounted."
fi

# Performance: Set CPU governors to performance
OLD_GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "powersave")
restore_governor() {
    if [[ -n "$OLD_GOV" ]]; then
        sudo bash -c "for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo '$OLD_GOV' > \"\$f\"; done" 2>/dev/null || true
    fi
}
trap restore_governor EXIT INT TERM

sudo bash -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f"; done' 2>/dev/null || true

# 1. Verify shared memory exists and has at least 32MB allocated
CURRENT_SIZE=$(stat -c %s "$SHM_FILE" 2>/dev/null || echo 0)
CURRENT_OWNER=$(stat -c %U "$SHM_FILE" 2>/dev/null || echo "")

if [[ ! -e "$SHM_FILE" || "$CURRENT_SIZE" -lt 33554432 || "$CURRENT_OWNER" != "$USER" ]]; then
    echo "[INFO] Allocating $SHM_FILE with 64MB memory (0660 $USER:kvm)..."
    if [[ -e "$SHM_FILE" && "$CURRENT_OWNER" != "$USER" ]]; then
        sudo rm -f "$SHM_FILE"
    fi
    touch "$SHM_FILE"
    truncate -s 64M "$SHM_FILE"
    chgrp kvm "$SHM_FILE" 2>/dev/null || sudo chown "$USER:kvm" "$SHM_FILE" 2>/dev/null || true
    chmod 0660 "$SHM_FILE" 2>/dev/null || sudo chmod 0660 "$SHM_FILE"
fi

# 2. Check read/write permissions
if [[ ! -r "$SHM_FILE" || ! -w "$SHM_FILE" ]]; then
    echo "[WARN] Fixing permissions on $SHM_FILE..."
    chmod 0660 "$SHM_FILE" 2>/dev/null || sudo chmod 0660 "$SHM_FILE"
fi

# 3. Check client binary
if ! command -v looking-glass-client >/dev/null 2>&1; then
    echo "[ERROR] looking-glass-client not found in PATH."
    echo "Please install looking-glass-client or compile it from source."
    exit 1
fi

# 4. Check if SPICE server is listening on port 5900
SPICE_ARGS=()
if ss -tln 2>/dev/null | grep -q ":5900\b"; then
    echo "[INFO] SPICE server detected on port 5900. Enabling mouse/keyboard capture..."
    SPICE_ARGS+=("spice:enable=yes" "spice:port=5900")
else
    echo "[INFO] SPICE server (port 5900) not active yet. Connecting in display-only mode..."
    SPICE_ARGS+=("spice:enable=no")
fi

# 5. Launch looking-glass-client with hardware EGL backend
echo "[INFO] Launching Looking Glass (Capture toggle: Right Control)..."
exec looking-glass-client -f "$SHM_FILE" -g egl "${SPICE_ARGS[@]}" "$@"
