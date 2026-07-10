#!/bin/bash
#
# setup_pktgen.sh
#
# Configures the kernel pktgen (packet generator) on one device for use
# with performance_analysis.sh.  Run this once before starting the test.
#
# Usage:
#   sudo ./setup_pktgen.sh [interface] [dst_mac] [dst_ip] [pkt_size] [count]
#
# Defaults (override via env or positional args):
#   interface  auto-detected from default route
#   dst_mac    ff:ff:ff:ff:ff:ff   (broadcast — change to real peer MAC)
#   dst_ip     192.168.1.1
#   pkt_size   1400                (bytes, excluding FCS)
#   count      0                   (0 = unlimited until "stop")
#
# Example:
#   sudo ./setup_pktgen.sh vf_eth0 aa:bb:cc:dd:ee:ff 10.0.0.2 1400 0

set -euo pipefail

# Auto-detect interface from default route if not given
_default_iface() {
    ip -o route show default 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}'
}

IFACE="${1:-${IFACE:-$(_default_iface)}}"
IFACE="${IFACE:-eth0}"
DST_MAC="${2:-${DST_MAC:-ff:ff:ff:ff:ff:ff}}"
DST_IP="${3:-${DST_IP:-192.168.1.1}}"
PKT_SIZE="${4:-${PKT_SIZE:-1400}}"
COUNT="${5:-${COUNT:-0}}"
THREADS="${THREADS:-1}"   # number of pktgen threads to use

###############################################################################
# Load pktgen module
###############################################################################

if ! lsmod | grep -q '^pktgen'; then
    echo "Loading pktgen module..."
    if ! modprobe pktgen 2>/dev/null; then
        echo "ERROR: could not load pktgen module."
        echo "       Check that your kernel was built with CONFIG_NET_PKTGEN=m:"
        echo "         grep CONFIG_NET_PKTGEN /boot/config-$(uname -r)"
        echo "       On Ubuntu, try a different kernel: linux-image-generic"
        exit 1
    fi
fi

PGDIR="/proc/net/pktgen"

if [ ! -d "$PGDIR" ]; then
    echo "ERROR: $PGDIR not found even after modprobe pktgen"
    exit 1
fi

###############################################################################
# Helper: write to a pktgen proc file
###############################################################################
pgset() {
    local file="$1"
    local value="$2"
    echo "$value" > "$file"
}

###############################################################################
# Configure threads and devices
###############################################################################

echo "Configuring pktgen: iface=$IFACE dst_mac=$DST_MAC dst_ip=$DST_IP pkt_size=$PKT_SIZE count=$COUNT threads=$THREADS"

for t in $(seq 0 $((THREADS - 1))); do
    THREAD_FILE="$PGDIR/kpktgend_${t}"

    if [ ! -f "$THREAD_FILE" ]; then
        echo "WARNING: thread file $THREAD_FILE not found, skipping"
        continue
    fi

    # Remove any existing device from this thread, then add ours
    pgset "$THREAD_FILE" "rem_device_all"
    pgset "$THREAD_FILE" "add_device ${IFACE}@${t}"

    DEV_FILE="$PGDIR/${IFACE}@${t}"

    # If the interface is on thread 0 without @N suffix, fall back
    if [ ! -f "$DEV_FILE" ]; then
        DEV_FILE="$PGDIR/${IFACE}"
    fi

    if [ ! -f "$DEV_FILE" ]; then
        echo "ERROR: device file $DEV_FILE not found"
        exit 1
    fi

    pgset "$DEV_FILE" "count $COUNT"
    pgset "$DEV_FILE" "pkt_size $PKT_SIZE"
    pgset "$DEV_FILE" "dst_mac $DST_MAC"
    pgset "$DEV_FILE" "dst $DST_IP"

    # Spread flows across cores to reduce contention
    pgset "$DEV_FILE" "flag QUEUE_MAP_CPU"

    echo "  Thread $t -> $DEV_FILE configured"
done

echo
echo "pktgen setup complete."
echo "  Start traffic : echo start > $PGDIR/pgctrl"
echo "  Stop  traffic : echo stop  > $PGDIR/pgctrl"
echo "  View  stats   : cat $PGDIR/${IFACE}"
echo
echo "performance_analysis.sh will start/stop pktgen automatically."
