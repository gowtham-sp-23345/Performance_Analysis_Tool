#!/bin/bash
#
# performance_analysis.sh
#
# Generic kernel performance analysis tool — measures CPU, memory, and network
# metrics before and after applying any livepatch.  No assumptions are made
# about which kernel subsystem the patch touches.
#
# Usage:
#   sudo ./performance_analysis.sh <output_dir> <run_number> <livepatch_ko>
#
# Example:
#   sudo ./performance_analysis.sh /tmp/results 1 /path/to/livepatch.ko
#
# Optional environment variables (all have sensible defaults):
#
#   INTERFACE        Network interface to collect ethtool/tc stats from.
#                    Default: auto-detected from the default route.
#
#   PKTGEN_DEV       pktgen device name (usually same as INTERFACE).
#                    Default: same as INTERFACE.
#                    Set to "" to skip pktgen entirely.
#
#   PKTGEN_DURATION  Seconds to run pktgen per phase.    Default: 60
#   PERF_DURATION    Seconds to run perf stat per phase. Default: 60
#
#   FTRACE_FUNC      Kernel function(s) to focus the function_graph tracer on.
#                    Accepts a comma-separated list or glob patterns supported
#                    by set_ftrace_filter (e.g. "net_rx_action,__netif_*").
#                    Default: "" — traces ALL kernel functions (broadest view).
#                    Set to a specific symbol to reduce trace volume.
#
# Requirements:
#   perf, kpatch, ftrace mounted at /sys/kernel/tracing
#   Optional: pktgen module, ethtool, numactl, mpstat, iostat

set -euo pipefail

###############################################################################
# Argument Parsing
###############################################################################

if [ $# -ne 3 ]; then
    echo "Usage: $0 <output_dir> <run_number> <livepatch_ko>"
    echo
    echo "  output_dir   : directory where all result files will be written"
    echo "  run_number   : integer label for this run (e.g. 1)"
    echo "  livepatch_ko : path to the signed livepatch kernel module (.ko)"
    exit 1
fi

TARGET_PATH="$1"
RUN_NUMBER="$2"
LIVEPATCH_KO="$3"

###############################################################################
# Configuration
###############################################################################

# Auto-detect default network interface if not explicitly set
if [ -z "${INTERFACE:-}" ]; then
    INTERFACE=$(ip -o route show default 2>/dev/null \
                | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1);exit}}')
    INTERFACE="${INTERFACE:-eth0}"
fi

PKTGEN_DEV="${PKTGEN_DEV:-$INTERFACE}"      # pktgen device (usually same as INTERFACE)
PKTGEN_DURATION="${PKTGEN_DURATION:-60}"    # seconds to run pktgen per phase
PERF_DURATION="${PERF_DURATION:-60}"        # seconds for perf stat per phase
FTRACE_FUNC="${FTRACE_FUNC:-}"              # empty = trace all kernel functions

###############################################################################
# Derived Paths
###############################################################################

OUTPUT_DIR="${TARGET_PATH}/performance_run_${RUN_NUMBER}"
TR="/sys/kernel/tracing"

mkdir -p "$OUTPUT_DIR"

LOG="${OUTPUT_DIR}/run.log"

# Redirect stdout+stderr to both terminal and log file
exec > >(tee -a "$LOG") 2>&1

echo "============================================================"
echo " Kernel Performance Analysis — Run ${RUN_NUMBER}"
echo " $(date)"
echo " Livepatch : $(basename "$LIVEPATCH_KO")"
echo " Interface : ${INTERFACE}"
echo " ftrace    : ${FTRACE_FUNC:-<all functions>}"
echo " Output    : ${OUTPUT_DIR}"
echo "============================================================"

###############################################################################
# Sanity Checks
###############################################################################

# Map tool names to their apt package on Ubuntu/Debian
_apt_pkg() {
    case "$1" in
        perf)   echo "linux-tools-$(uname -r) linux-tools-common" ;;
        kpatch) echo "kpatch" ;;
        tc)     echo "iproute2" ;;
        ip)     echo "iproute2" ;;
        *)      echo "$1" ;;
    esac
}

# Ensure tracefs is mounted; try debugfs fallback on older kernels
_ensure_tracefs() {
    if mountpoint -q "$TR" 2>/dev/null || [ -f "$TR/tracing_on" ]; then
        return 0
    fi
    # Fallback: tracefs may be under debugfs on older kernels
    if [ -f /sys/kernel/debug/tracing/tracing_on ]; then
        TR="/sys/kernel/debug/tracing"
        echo "  tracefs found via debugfs at $TR"
        return 0
    fi
    echo "Mounting tracefs at $TR..."
    mkdir -p "$TR"
    if mount -t tracefs nodev "$TR" 2>/dev/null; then
        echo "  tracefs mounted."
        return 0
    fi
    echo "ERROR: cannot mount tracefs at $TR"
    echo "       Your kernel may need CONFIG_FTRACE=y"
    echo "       Try: sudo apt-get install linux-headers-$(uname -r)"
    return 1
}

check_requirements() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: this script must be run as root"
        exit 1
    fi

    # Check required commands, print apt install hints for anything missing
    local missing=()
    for cmd in perf kpatch tc ip; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: missing required tools: ${missing[*]}"
        echo
        echo "Install on Ubuntu/Debian:"
        for cmd in "${missing[@]}"; do
            echo "  sudo apt-get install $(_apt_pkg "$cmd")"
        done
        echo
        echo "Or run:  sudo ./install_deps.sh"
        exit 1
    fi

    # Ensure tracefs is accessible (auto-mount if needed)
    _ensure_tracefs || exit 1

    if [ ! -f "$LIVEPATCH_KO" ]; then
        echo "ERROR: livepatch module not found: $LIVEPATCH_KO"
        exit 1
    fi

    # Auto-load pktgen if PKTGEN_DEV is set but module is not loaded
    if [ -n "$PKTGEN_DEV" ] && [ ! -d /proc/net/pktgen ]; then
        echo "Loading pktgen module..."
        if modprobe pktgen 2>/dev/null; then
            echo "  pktgen loaded."
        else
            echo "WARNING: pktgen module could not be loaded."
            echo "         Your kernel needs CONFIG_NET_PKTGEN=m"
            echo "         Continuing without pktgen (set PKTGEN_DEV='' to suppress this warning)."
        fi
    fi
}

check_requirements

###############################################################################
# System Information Snapshot
###############################################################################

collect_sysinfo() {
    local outfile="$1"
    echo "Collecting system information -> $(basename "$outfile")"

    {
        echo "============================================================"
        echo " System Information — $(date)"
        echo "============================================================"

        echo
        echo "#################### Kernel ####################"
        echo
        echo "--- uname -a ---"
        uname -a
        echo
        echo "--- /proc/version ---"
        cat /proc/version
        echo
        echo "--- /proc/cmdline ---"
        cat /proc/cmdline
        echo
        echo "--- /etc/os-release ---"
        cat /etc/os-release
        echo
        echo "--- hostnamectl ---"
        hostnamectl 2>/dev/null || true
        echo
        echo "--- ASLR ---"
        sysctl kernel.randomize_va_space

        echo
        echo "#################### Livepatch ####################"
        if [ -d /sys/kernel/livepatch ] && [ -n "$(ls /sys/kernel/livepatch 2>/dev/null)" ]; then
            for patch in /sys/kernel/livepatch/*; do
                [ -d "$patch" ] || continue
                echo
                echo "Patch     : $(basename "$patch")"
                [ -f "$patch/enabled"    ] && echo "Enabled   : $(cat "$patch/enabled")"
                [ -f "$patch/transition" ] && echo "Transition: $(cat "$patch/transition")"
            done
        else
            echo "(no livepatches loaded)"
        fi

        echo
        echo "#################### Tracing — FTRACE_FUNC: ${FTRACE_FUNC:-<all>} ####################"
        echo "tracing_on     : $(cat $TR/tracing_on)"
        echo "current_tracer : $(cat $TR/current_tracer)"
        echo "set_ftrace_filter:"
        cat "$TR/set_ftrace_filter"

        echo
        echo "#################### CPU ####################"
        lscpu
        echo
        echo "--- MHz ---"
        grep "MHz" /proc/cpuinfo || true
        echo
        echo "--- Governor ---"
        for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -f "$gov" ] && cat "$gov" && break
        done 2>/dev/null || echo "(unavailable)"

        echo
        echo "#################### Memory ####################"
        free -h
        echo
        cat /proc/meminfo
        echo
        echo "--- Huge Pages ---"
        grep -i huge /proc/meminfo || true

        echo
        echo "#################### NUMA ####################"
        if command -v numactl >/dev/null 2>&1; then
            numactl --hardware
        else
            echo "(numactl not installed)"
        fi

        echo
        echo "#################### Network — $INTERFACE ####################"
        echo
        echo "--- ip addr ---"
        ip addr show
        echo
        echo "--- ip link ---"
        ip link show

        if command -v ethtool >/dev/null 2>&1; then
            echo
            echo "--- Driver ($INTERFACE) ---"
            ethtool -i "$INTERFACE" 2>/dev/null || true
            echo
            echo "--- Interface settings ---"
            ethtool "$INTERFACE" 2>/dev/null || true
            echo
            echo "--- Offloads ---"
            ethtool -k "$INTERFACE" 2>/dev/null || true
            echo
            echo "--- Ring Parameters ---"
            ethtool -g "$INTERFACE" 2>/dev/null || true
            echo
            echo "--- Channels ---"
            ethtool -l "$INTERFACE" 2>/dev/null || true
            echo
            echo "--- Statistics ---"
            ethtool -S "$INTERFACE" 2>/dev/null || true
        fi

        echo
        echo "#################### Traffic Control — $INTERFACE ####################"
        echo
        echo "--- qdisc ---"
        tc qdisc show 2>/dev/null || true
        echo
        echo "--- filters (ingress) ---"
        tc filter show dev "$INTERFACE" ingress 2>/dev/null || true
        echo
        echo "--- filters (egress) ---"
        tc filter show dev "$INTERFACE" egress 2>/dev/null || true
        echo
        echo "--- filter statistics (egress) ---"
        tc -s filter show dev "$INTERFACE" egress 2>/dev/null || true
        echo
        echo "--- all tc actions ---"
        for act in $(tc actions ls 2>/dev/null | grep -oP 'action \K\S+' | sort -u); do
            echo "  action type: $act"
            tc actions ls action "$act" 2>/dev/null | sed 's/^/    /' || true
        done

        echo
        echo "#################### Interrupts ####################"
        echo
        cat /proc/interrupts
        echo
        echo "--- softirqs ---"
        cat /proc/softirqs

        echo
        echo "#################### System Load ####################"
        uptime
        echo
        echo "--- vmstat (1s x 5) ---"
        vmstat 1 5
        echo
        if command -v mpstat >/dev/null 2>&1; then
            echo "--- mpstat (1s x 5) ---"
            mpstat -P ALL 1 5
        fi
        if command -v iostat >/dev/null 2>&1; then
            echo "--- iostat (1s x 5) ---"
            iostat -xz 1 5
        fi

        echo
        echo "#################### Loaded Modules ####################"
        lsmod

        echo
        echo "#################### Kernel Config ####################"
        if [ -f /proc/config.gz ]; then
            zcat /proc/config.gz
        elif [ -f "/boot/config-$(uname -r)" ]; then
            cat "/boot/config-$(uname -r)"
        else
            echo "(kernel config not found)"
        fi

    } > "$outfile"

    echo "  -> done"
}

###############################################################################
# perf stat
###############################################################################

run_perf_stat() {
    local outfile="$1"
    local label="$2"
    echo "Running perf stat ($label, ${PERF_DURATION}s) -> $(basename "$outfile")"

    perf stat \
        -a \
        -e cycles,instructions,branches,branch-misses,\
cache-references,cache-misses,task-clock,\
context-switches,cpu-migrations,\
L1-dcache-loads,L1-dcache-load-misses,\
LLC-loads,LLC-load-misses \
        -- sleep "$PERF_DURATION" \
        2> "$outfile"

    echo "  -> done"
}

###############################################################################
# ftrace + pktgen measurement
###############################################################################

ftrace_reset() {
    echo 0   > "$TR/tracing_on"
    echo nop > "$TR/current_tracer"
    echo     > "$TR/trace"
    echo     > "$TR/set_ftrace_filter"
    echo     > "$TR/set_graph_function"
}

run_pktgen_ftrace() {
    local trace_out="$1"
    local pktgen_out="$2"
    local label="$3"

    echo "Running ftrace ($label, ${PKTGEN_DURATION}s) -> $(basename "$trace_out")"

    ftrace_reset

    echo function_graph > "$TR/current_tracer"

    if [ -n "$FTRACE_FUNC" ]; then
        # Filter to the specific function(s) requested
        echo "$FTRACE_FUNC" > "$TR/set_graph_function"
        echo "$FTRACE_FUNC" > "$TR/set_ftrace_filter"
        echo "  ftrace filter : $FTRACE_FUNC"
    else
        # No filter — trace all kernel functions (generic, works for any patch)
        echo "  ftrace filter : <all functions>"
    fi

    echo 1 > "$TR/tracing_on"

    # Run pktgen if available, otherwise just sleep so ftrace captures live traffic
    if [ -n "$PKTGEN_DEV" ] && [ -d /proc/net/pktgen ]; then
        echo "start" > /proc/net/pktgen/pgctrl
        sleep "$PKTGEN_DURATION"
        echo "stop"  > /proc/net/pktgen/pgctrl
        cp "/proc/net/pktgen/$PKTGEN_DEV" "$pktgen_out" 2>/dev/null || \
            echo "(pktgen device report unavailable)" > "$pktgen_out"
    else
        echo "  (pktgen not configured — sleeping ${PKTGEN_DURATION}s under ftrace)"
        sleep "$PKTGEN_DURATION"
        echo "(pktgen not used)" > "$pktgen_out"
    fi

    echo 0 > "$TR/tracing_on"
    cp "$TR/trace" "$trace_out"
    ftrace_reset

    echo "  -> trace  : $(basename "$trace_out")"
    echo "  -> pktgen : $(basename "$pktgen_out")"
}

###############################################################################
# PHASE 1 — Before Patch
###############################################################################

echo
echo "============================================================"
echo " PHASE 1: Before Patch"
echo "============================================================"

collect_sysinfo "${OUTPUT_DIR}/sysinfo_before_patch.txt"

run_perf_stat \
    "${OUTPUT_DIR}/perf_stat_before_patch.txt" \
    "before patch"

run_pktgen_ftrace \
    "${OUTPUT_DIR}/ftrace_before_patch_${RUN_NUMBER}.txt" \
    "${OUTPUT_DIR}/pktgen_report_before_patch.txt" \
    "before patch"

echo
echo "Phase 1 complete."

###############################################################################
# PHASE 2 — Apply Livepatch
###############################################################################

echo
echo "============================================================"
echo " PHASE 2: Applying Livepatch"
echo "============================================================"
echo "Loading: $LIVEPATCH_KO"

kpatch load "$LIVEPATCH_KO"

echo "Waiting for livepatch transition to complete..."
for i in $(seq 1 60); do
    transition=$(cat /sys/kernel/livepatch/*/transition 2>/dev/null | head -1)
    if [ "${transition:-0}" = "0" ]; then
        echo "  -> Transition complete (${i}s)"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo "  WARNING: transition still in progress after 60s, continuing anyway"
    fi
    sleep 1
done

echo
echo "Livepatch status:"
for patch in /sys/kernel/livepatch/*; do
    [ -d "$patch" ] || continue
    echo "  Patch     : $(basename "$patch")"
    [ -f "$patch/enabled"    ] && echo "  Enabled   : $(cat "$patch/enabled")"
    [ -f "$patch/transition" ] && echo "  Transition: $(cat "$patch/transition")"
done

###############################################################################
# PHASE 3 — After Patch
###############################################################################

echo
echo "============================================================"
echo " PHASE 3: After Patch"
echo "============================================================"

collect_sysinfo "${OUTPUT_DIR}/sysinfo_after_patch.txt"

run_perf_stat \
    "${OUTPUT_DIR}/perf_stat_after_patch.txt" \
    "after patch"

run_pktgen_ftrace \
    "${OUTPUT_DIR}/ftrace_after_patch_${RUN_NUMBER}.txt" \
    "${OUTPUT_DIR}/pktgen_report_after_patch.txt" \
    "after patch"

echo
echo "Phase 3 complete."

###############################################################################
# Summary
###############################################################################

echo
echo "============================================================"
echo " Summary"
echo "============================================================"

SUMMARY="${OUTPUT_DIR}/summary_${RUN_NUMBER}.txt"
{
    echo "Kernel Performance Analysis — Run ${RUN_NUMBER}"
    echo "Date      : $(date)"
    echo "Kernel    : $(uname -r)"
    echo "Patch     : $(basename "$LIVEPATCH_KO")"
    echo "Interface : $INTERFACE"
    echo "ftrace    : ${FTRACE_FUNC:-<all functions>}"
    echo

    echo "--- pktgen: before patch ---"
    grep -E "^(Result|Params|pkts-sofar|errors|throughput|pps)" \
        "${OUTPUT_DIR}/pktgen_report_before_patch.txt" 2>/dev/null || \
        cat "${OUTPUT_DIR}/pktgen_report_before_patch.txt"
    echo

    echo "--- pktgen: after patch ---"
    grep -E "^(Result|Params|pkts-sofar|errors|throughput|pps)" \
        "${OUTPUT_DIR}/pktgen_report_after_patch.txt" 2>/dev/null || \
        cat "${OUTPUT_DIR}/pktgen_report_after_patch.txt"
    echo

    echo "--- perf stat: before patch ---"
    cat "${OUTPUT_DIR}/perf_stat_before_patch.txt"
    echo

    echo "--- perf stat: after patch ---"
    cat "${OUTPUT_DIR}/perf_stat_after_patch.txt"
    echo

    echo "--- ftrace line counts ---"
    echo "  before : $(wc -l < "${OUTPUT_DIR}/ftrace_before_patch_${RUN_NUMBER}.txt") lines"
    echo "  after  : $(wc -l < "${OUTPUT_DIR}/ftrace_after_patch_${RUN_NUMBER}.txt") lines"

} > "$SUMMARY"

cat "$SUMMARY"

echo
echo "All results saved under: ${OUTPUT_DIR}"
echo "Run ./compare_results.sh ${TARGET_PATH} ${RUN_NUMBER} to analyze."
