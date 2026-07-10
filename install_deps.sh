#!/bin/bash
#
# install_deps.sh
#
# Installs all dependencies required by the kernel performance analysis tool
# on any Ubuntu or Debian machine.
#
# Usage:
#   sudo ./install_deps.sh
#
# What it installs:
#   perf          - CPU hardware counter profiler  (linux-tools-<kernel>)
#   kpatch        - live kernel patching tool
#   ethtool       - NIC driver/offload/stats queries
#   iproute2      - ip, tc commands
#   numactl       - NUMA topology info (optional, improves sysinfo)
#   sysstat       - mpstat, iostat (optional, improves sysinfo)
#   linux-headers - needed by kpatch-build if you build your own patches
#   tcpdump       - used by remap test harness (optional here)

set -euo pipefail

###############################################################################
# OS check
###############################################################################

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run as root:  sudo $0"
    exit 1
fi

if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
    echo "WARNING: this script targets Ubuntu/Debian."
    echo "         Detected OS:"
    grep PRETTY_NAME /etc/os-release 2>/dev/null || cat /etc/os-release
    read -rp "Continue anyway? [y/N] " ans
    [[ "${ans,,}" == "y" ]] || exit 0
fi

KERNEL=$(uname -r)
echo "============================================================"
echo " Dependency installer — kernel: $KERNEL"
echo " $(date)"
echo "============================================================"

###############################################################################
# apt update
###############################################################################

echo
echo "[1/5] Updating package lists..."
apt-get update -qq

###############################################################################
# Core tools
###############################################################################

echo
echo "[2/5] Installing core tools (iproute2, ethtool, curl, tcpdump)..."

apt-get install -y \
    iproute2 \
    ethtool \
    curl \
    tcpdump

# kpatch: skip if already installed (commonly built from source)
echo
if command -v kpatch >/dev/null 2>&1; then
    echo "kpatch already installed: $(command -v kpatch)  version: $(kpatch -v 2>&1 || true)"
else
    echo "kpatch not found. Attempting apt install..."
    if apt-get install -y kpatch 2>/dev/null; then
        echo "  kpatch installed via apt."
    else
        echo
        echo "  apt package 'kpatch' not available on this system."
        echo "  Install from source:"
        echo "    sudo apt-get install -y git build-essential libelf-dev"
        echo "    git clone https://github.com/dynup/kpatch.git"
        echo "    cd kpatch && make && sudo make install"
        echo
        echo "  Continuing — install kpatch manually before running performance_analysis.sh."
    fi
fi

###############################################################################
# perf — kernel-version-specific package
###############################################################################

echo
echo "[3/5] Installing perf for kernel $KERNEL..."

# Try exact kernel version first, fall back to generic linux-perf
PERF_PKG="linux-tools-${KERNEL}"
if apt-cache show "$PERF_PKG" >/dev/null 2>&1; then
    apt-get install -y "$PERF_PKG"
else
    echo "  Exact package $PERF_PKG not found, trying linux-tools-generic..."
    apt-get install -y linux-tools-generic || true
fi

# Also install linux-tools-common which provides the perf wrapper
apt-get install -y linux-tools-common 2>/dev/null || true

###############################################################################
# Optional tools (improve sysinfo quality — non-fatal if unavailable)
###############################################################################

echo
echo "[4/5] Installing optional tools (numactl, sysstat, linux-headers)..."

OPTIONAL_PKGS=(
    numactl           # NUMA topology (numactl --hardware)
    sysstat           # mpstat, iostat
    "linux-headers-${KERNEL}"  # needed if you build livepatches with kpatch-build
)

for pkg in "${OPTIONAL_PKGS[@]}"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
        apt-get install -y "$pkg" || \
            echo "  WARNING: could not install $pkg (non-fatal, continuing)"
    else
        echo "  SKIP: $pkg not found in apt cache"
    fi
done

###############################################################################
# pktgen — kernel module, no package needed
###############################################################################

echo
echo "[5/5] Checking pktgen kernel module..."

if modprobe pktgen 2>/dev/null; then
    echo "  pktgen module loaded successfully."
    echo "  (it will be loaded automatically on next run if needed)"
else
    echo "  WARNING: pktgen module could not be loaded."
    echo "           This is non-fatal — set PKTGEN_DEV='' to skip pktgen."
    echo "           pktgen requires: CONFIG_NET_PKTGEN=m in your kernel config."
fi

###############################################################################
# tracefs — mount if not already mounted
###############################################################################

echo
echo "Checking tracefs (ftrace)..."

if [ -d /sys/kernel/tracing ] && mountpoint -q /sys/kernel/tracing 2>/dev/null; then
    echo "  tracefs already mounted at /sys/kernel/tracing"
elif [ -d /sys/kernel/debug/tracing ]; then
    echo "  tracefs found via debugfs at /sys/kernel/debug/tracing"
    echo "  Creating symlink /sys/kernel/tracing -> /sys/kernel/debug/tracing"
    ln -sf /sys/kernel/debug/tracing /sys/kernel/tracing 2>/dev/null || true
else
    echo "  Mounting tracefs at /sys/kernel/tracing..."
    mkdir -p /sys/kernel/tracing
    mount -t tracefs nodev /sys/kernel/tracing 2>/dev/null && \
        echo "  mounted." || \
        echo "  WARNING: could not mount tracefs (kernel may not have CONFIG_FTRACE=y)"
fi

# Persist the tracefs mount across reboots
FSTAB_ENTRY="nodev /sys/kernel/tracing tracefs defaults 0 0"
if ! grep -qF "tracefs" /etc/fstab 2>/dev/null; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
    echo "  Added tracefs to /etc/fstab for persistence."
fi

###############################################################################
# Verify
###############################################################################

echo
echo "============================================================"
echo " Verification"
echo "============================================================"

ALL_OK=true
for cmd in perf kpatch ip tc ethtool; do
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "  %-12s OK  (%s)\n" "$cmd" "$(command -v "$cmd")"
    else
        printf "  %-12s MISSING\n" "$cmd"
        ALL_OK=false
    fi
done

for cmd in numactl mpstat iostat; do
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "  %-12s OK  (optional)\n" "$cmd"
    else
        printf "  %-12s not found  (optional — sysinfo will be partial)\n" "$cmd"
    fi
done

echo
if [ -d /sys/kernel/tracing ]; then
    echo "  tracefs     OK  (/sys/kernel/tracing)"
else
    echo "  tracefs     MISSING  (/sys/kernel/tracing)"
    ALL_OK=false
fi

if [ -d /proc/net/pktgen ]; then
    echo "  pktgen      OK  (/proc/net/pktgen)"
else
    echo "  pktgen      not loaded  (set PKTGEN_DEV='' if you don't need it)"
fi

echo
if $ALL_OK; then
    echo "All required dependencies are present."
    echo "You can now run:"
    echo "  sudo ./setup_pktgen.sh                    # optional — configure pktgen"
    echo "  sudo ./performance_analysis.sh <outdir> <run#> <livepatch.ko>"
else
    echo "Some required dependencies are missing. See warnings above."
    exit 1
fi
