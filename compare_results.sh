#!/bin/bash
#
# compare_results.sh
#
# Parses and compares perf stat + pktgen + ftrace results from before and after
# any livepatch.  Works generically for any kernel patch — no assumptions about
# which subsystem was patched.
#
# Usage:
#   ./compare_results.sh <output_dir> <run_number>
#
# Optional: set FTRACE_FUNC to the same value used during collection to get
# per-function invocation counts.  Leave unset for generic analysis.

set -euo pipefail

if [ $# -ne 2 ]; then
    echo "Usage: $0 <output_dir> <run_number>"
    exit 1
fi

TARGET_PATH="$1"
RUN_NUMBER="$2"
OUTPUT_DIR="${TARGET_PATH}/performance_run_${RUN_NUMBER}"

PERF_BP="${OUTPUT_DIR}/perf_stat_before_patch.txt"
PERF_AP="${OUTPUT_DIR}/perf_stat_after_patch.txt"
PKTGEN_BP="${OUTPUT_DIR}/pktgen_report_before_patch.txt"
PKTGEN_AP="${OUTPUT_DIR}/pktgen_report_after_patch.txt"
FTRACE_BP="${OUTPUT_DIR}/ftrace_before_patch_${RUN_NUMBER}.txt"
FTRACE_AP="${OUTPUT_DIR}/ftrace_after_patch_${RUN_NUMBER}.txt"
REPORT="${OUTPUT_DIR}/comparison_report_${RUN_NUMBER}.txt"

# Check all required files exist
for f in "$PERF_BP" "$PERF_AP" "$PKTGEN_BP" "$PKTGEN_AP"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: required file not found: $f"
        exit 1
    fi
done

###############################################################################
# Helpers
###############################################################################

# Extract a numeric value (removing commas) from perf stat output.
# perf stat format:  "     1,234,567      event-name   #  ..."
extract_perf() {
    local file="$1"
    local event="$2"
    grep -w "$event" "$file" 2>/dev/null \
        | awk '{gsub(/,/,"",$1); print $1}' \
        | head -1
}

# Compute percentage change: (after - before) / before * 100
# Prints with sign, e.g. +3.45% or -1.23%
pct_change() {
    local before="$1"
    local after="$2"
    awk -v b="$before" -v a="$after" 'BEGIN {
        if (b == 0) { print "N/A"; exit }
        d = (a - b) / b * 100
        printf "%+.2f%%\n", d
    }'
}

# Print a comparison row
row() {
    local label="$1"
    local before="$2"
    local after="$3"
    local change
    change=$(pct_change "$before" "$after")
    printf "  %-30s  %20s  %20s  %10s\n" "$label" "$before" "$after" "$change"
}

header() {
    printf "  %-30s  %20s  %20s  %10s\n" "$1" "BEFORE" "AFTER" "CHANGE"
    printf "  %-30s  %20s  %20s  %10s\n" \
        "------------------------------" \
        "--------------------" \
        "--------------------" \
        "----------"
}

###############################################################################
# perf stat comparison
###############################################################################

compare_perf() {
    echo
    echo "##############################################################"
    echo " perf stat comparison"
    echo "##############################################################"

    header "Event"

    local events=(
        cycles
        instructions
        branches
        branch-misses
        cache-references
        cache-misses
        task-clock
        context-switches
        cpu-migrations
        L1-dcache-loads
        L1-dcache-load-misses
        LLC-loads
        LLC-load-misses
    )

    for event in "${events[@]}"; do
        b=$(extract_perf "$PERF_BP" "$event")
        a=$(extract_perf "$PERF_AP" "$event")
        if [ -n "$b" ] && [ -n "$a" ]; then
            row "$event" "$b" "$a"
        fi
    done

    # IPC (instructions per cycle) — derived
    echo
    echo "  Derived metrics:"
    header "Metric"
    local cyc_b cyc_a ins_b ins_a ipc_b ipc_a
    cyc_b=$(extract_perf "$PERF_BP" "cycles")
    cyc_a=$(extract_perf "$PERF_AP" "cycles")
    ins_b=$(extract_perf "$PERF_BP" "instructions")
    ins_a=$(extract_perf "$PERF_AP" "instructions")

    if [ -n "$cyc_b" ] && [ -n "$ins_b" ] && [ "$cyc_b" -gt 0 ] && [ "$cyc_a" -gt 0 ]; then
        ipc_b=$(awk -v i="$ins_b" -v c="$cyc_b" 'BEGIN{printf "%.4f", i/c}')
        ipc_a=$(awk -v i="$ins_a" -v c="$cyc_a" 'BEGIN{printf "%.4f", i/c}')
        row "IPC (instr/cycle)" "$ipc_b" "$ipc_a"
    fi

    local cm_b cm_a cr_b cr_a
    cm_b=$(extract_perf "$PERF_BP" "cache-misses")
    cm_a=$(extract_perf "$PERF_AP" "cache-misses")
    cr_b=$(extract_perf "$PERF_BP" "cache-references")
    cr_a=$(extract_perf "$PERF_AP" "cache-references")

    if [ -n "$cm_b" ] && [ -n "$cr_b" ] && [ "$cr_b" -gt 0 ] && [ "$cr_a" -gt 0 ]; then
        local cmr_b cmr_a
        cmr_b=$(awk -v m="$cm_b" -v r="$cr_b" 'BEGIN{printf "%.4f", m/r*100}')
        cmr_a=$(awk -v m="$cm_a" -v r="$cr_a" 'BEGIN{printf "%.4f", m/r*100}')
        row "Cache miss rate (%)" "$cmr_b" "$cmr_a"
    fi
}

###############################################################################
# pktgen comparison
###############################################################################

# Extract a value from pktgen /proc output by keyword
extract_pktgen() {
    local file="$1"
    local key="$2"
    grep -i "$key" "$file" 2>/dev/null \
        | grep -oP '[0-9]+(\.[0-9]+)?' \
        | head -1
}

compare_pktgen() {
    echo
    echo "##############################################################"
    echo " pktgen comparison"
    echo "##############################################################"

    echo
    echo "  Before patch:"
    sed 's/^/    /' "$PKTGEN_BP"
    echo
    echo "  After patch:"
    sed 's/^/    /' "$PKTGEN_AP"

    # Attempt numeric comparison on common pktgen fields
    echo
    header "pktgen metric"

    for key in "pps" "bps" "pkts-sofar" "errors"; do
        b=$(extract_pktgen "$PKTGEN_BP" "$key")
        a=$(extract_pktgen "$PKTGEN_AP" "$key")
        if [ -n "$b" ] && [ -n "$a" ]; then
            row "$key" "$b" "$a"
        fi
    done
}

###############################################################################
# ftrace comparison
###############################################################################

compare_ftrace() {
    echo
    echo "##############################################################"
    echo " ftrace comparison"
    echo "##############################################################"

    if [ ! -f "$FTRACE_BP" ] || [ ! -f "$FTRACE_AP" ]; then
        echo "  (ftrace files not found, skipping)"
        return
    fi

    local lines_b lines_a
    lines_b=$(wc -l < "$FTRACE_BP")
    lines_a=$(wc -l < "$FTRACE_AP")

    header "Metric"
    row "trace lines (proxy for call count)" "$lines_b" "$lines_a"

    # Count function invocations generically or for a specific function
    local calls_b calls_a
    if [ -n "${FTRACE_FUNC:-}" ]; then
        # A specific function was traced — count its appearances directly
        calls_b=$(grep -cF "$FTRACE_FUNC" "$FTRACE_BP" 2>/dev/null || echo 0)
        calls_a=$(grep -cF "$FTRACE_FUNC" "$FTRACE_AP" 2>/dev/null || echo 0)
        row "invocations of $FTRACE_FUNC" "$calls_b" "$calls_a"
    else
        # Generic: count all function_graph call entry lines (contain '()')
        calls_b=$(grep -c '|.*()' "$FTRACE_BP" 2>/dev/null || echo 0)
        calls_a=$(grep -c '|.*()' "$FTRACE_AP" 2>/dev/null || echo 0)
        row "total function call entries" "$calls_b" "$calls_a"

        echo
        echo "  Top 10 most-called functions — before patch:"
        grep -oP '\|\s+\K[a-z_][a-zA-Z0-9_.]+(?= \()' "$FTRACE_BP" 2>/dev/null \
            | sort | uniq -c | sort -rn | head -10 \
            | awk '{printf "    %8s  %s\n",$1,$2}' || true

        echo
        echo "  Top 10 most-called functions — after patch:"
        grep -oP '\|\s+\K[a-z_][a-zA-Z0-9_.]+(?= \()' "$FTRACE_AP" 2>/dev/null \
            | sort | uniq -c | sort -rn | head -10 \
            | awk '{printf "    %8s  %s\n",$1,$2}' || true
    fi

    # Average duration if function_graph format: lines like "  X.XXX us"
    echo
    echo "  Top 10 slowest calls — before patch:"
    grep -oP '[0-9]+\.[0-9]+ us' "$FTRACE_BP" 2>/dev/null \
        | awk '{gsub(/ us/,""); print $1}' \
        | sort -rn | head -10 | awk '{printf "    %s us\n",$1}' || true

    echo
    echo "  Top 10 slowest calls — after patch:"
    grep -oP '[0-9]+\.[0-9]+ us' "$FTRACE_AP" 2>/dev/null \
        | awk '{gsub(/ us/,""); print $1}' \
        | sort -rn | head -10 | awk '{printf "    %s us\n",$1}' || true
}

###############################################################################
# sysinfo diff (kernel version, modules, tc rules)
###############################################################################

compare_sysinfo() {
    local si_b="${OUTPUT_DIR}/sysinfo_before_patch.txt"
    local si_a="${OUTPUT_DIR}/sysinfo_after_patch.txt"

    if [ ! -f "$si_b" ] || [ ! -f "$si_a" ]; then
        return
    fi

    echo
    echo "##############################################################"
    echo " sysinfo diff (before vs after)"
    echo "##############################################################"
    diff --unified=1 "$si_b" "$si_a" || true
}

###############################################################################
# Main
###############################################################################

{
    echo "============================================================"
    echo " Kernel Performance Comparison Report"
    echo " Run       : ${RUN_NUMBER}"
    echo " Directory : ${OUTPUT_DIR}"
    echo " Date      : $(date)"
    echo "============================================================"

    compare_perf
    compare_pktgen
    compare_ftrace
    compare_sysinfo

    echo
    echo "============================================================"
    echo " End of Report"
    echo "============================================================"

} | tee "$REPORT"

echo
echo "Report saved: $REPORT"
