#!/usr/bin/env bash
# ==============================================================================
# install-client.sh - Automated Looking Glass Client Builder & Installer (B7)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

log_header "Installing Looking Glass Client (Version B7)"

BUILD_DEPS=(
    cmake
    ninja-build
    binutils-dev
    libspice-protocol-dev
    nettle-dev
    libfontconfig-dev
    libx11-dev
    libxcursor-dev
    libxi-dev
    libxinerama-dev
    libxrandr-dev
    libxss-dev
    libxpresent-dev
    libdecor-0-dev
    libgl-dev
    libegl-dev
    libepoxy-dev
    libpipewire-0.3-dev
    libpulse-dev
    libsamplerate0-dev
    pkg-config
    git
)

# 1. Check and install missing dependencies
MISSING_DEPS=()
for pkg in "${BUILD_DEPS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_DEPS+=("$pkg")
    fi
done

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    log_step "Installing missing build dependencies: ${MISSING_DEPS[*]}"
    sudo apt update
    sudo apt install -y "${MISSING_DEPS[@]}"
    log_success "Build dependencies installed."
else
    log_success "All required build dependencies are already installed."
fi

# 2. Prepare Source Code
SRC_DIR="/tmp/LookingGlass"
if [[ ! -d "${SRC_DIR}/.git" ]]; then
    log_step "Cloning Looking Glass repository (Tag: B7)..."
    rm -rf "$SRC_DIR"
    git clone --branch B7 https://github.com/gnif/LookingGlass.git "$SRC_DIR"
fi

log_info "Synchronizing and checking out exact submodules..."
cd "$SRC_DIR"
git checkout .
git submodule sync --recursive
if ! git submodule update --checkout --init --recursive; then
    log_warn "Submodule checkout needed deep fetch, resolving nested submodules..."
    if [[ -d "${SRC_DIR}/repos/cimgui/imgui" ]]; then
        git -C "${SRC_DIR}/repos/cimgui/imgui" fetch origin dbb5eeaadffb6a3ba6a60de1290312e5802dba5a 2>/dev/null || true
        git -C "${SRC_DIR}/repos/cimgui/imgui" checkout dbb5eeaadffb6a3ba6a60de1290312e5802dba5a 2>/dev/null || true
    fi
    git submodule update --checkout --init --recursive
fi

# 3. Configure and Compile
log_step "Configuring and Building looking-glass-client..."
BUILD_DIR="${SRC_DIR}/client/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake -GNinja -DDEVELOPER=ON -DENABLE_WAYLAND=ON -DENABLE_X11=ON ..
ninja

log_success "Compilation completed successfully!"

# 4. Install Binary
log_step "Installing looking-glass-client binary..."
sudo cp looking-glass-client /usr/local/bin/looking-glass-client
sudo chmod 755 /usr/local/bin/looking-glass-client

# Also symlink to user local bin if exists
mkdir -p "${HOME}/.local/bin"
ln -sf /usr/local/bin/looking-glass-client "${HOME}/.local/bin/looking-glass-client"

log_header "Looking Glass Client Installation Complete!"
log_success "Installed to: /usr/local/bin/looking-glass-client"
log_info "You can now launch it anytime from any terminal using:"
log_info "  looking-glass-run"
log_info "  or: vfio-launch [vm_name]"
