#!/usr/bin/env bash
#
# vm_health.sh - Analyze the health of a virtual machine.
#
# Checks CPU, memory, and disk utilization. If any of the three is above
# 60% utilized, the VM is declared UNHEALTHY; otherwise it is HEALTHY.
#
# Usage:
#   ./vm_health.sh            print health status only
#   ./vm_health.sh explain    print health status plus the reason
#
# Options:
#   -w PERCENT   warning threshold (default: 60)
#   -d PATH      filesystem path to check for disk usage (default: /)
#   -h           show this help

set -euo pipefail

THRESHOLD=60
DISK_PATH="/"

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

while getopts "w:d:h" opt; do
    case "$opt" in
        w) THRESHOLD="$OPTARG" ;;
        d) DISK_PATH="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

if [[ "${1:-}" != "" && "${1:-}" != "explain" ]]; then
    echo "Unknown argument: $1" >&2
    echo "Usage: $0 [explain]" >&2
    exit 2
fi

EXPLAIN=false
if [[ "${1:-}" == "explain" ]]; then
    EXPLAIN=true
fi

# ---------------------------------------------------------------------------
# Metric collection
# ---------------------------------------------------------------------------

# CPU utilization: sample /proc/stat twice over a short interval and
# compute the busy percentage. Works on any Linux VM without extra packages.
cpu_usage() {
    local line1 line2
    line1=$(grep '^cpu ' /proc/stat)
    sleep 1
    line2=$(grep '^cpu ' /proc/stat)

    awk -v l1="$line1" -v l2="$line2" '
        function sum(line,   i, vals, total) {
            split(line, vals, " ")
            total = 0
            for (i = 2; i <= 11; i++) total += vals[i]
            return total
        }
        function idle(line) {
            split(line, vals, " ")
            return vals[6] + vals[5]   # idle + iowait
        }
        BEGIN {
            t1 = sum(l1); i1 = idle(l1)
            t2 = sum(l2); i2 = idle(l2)
            dt = t2 - t1; di = i2 - i1
            if (dt <= 0) { print 0; exit }
            printf "%.1f", (dt - di) * 100 / dt
        }'
}

# Memory utilization from /proc/meminfo (MemAvailable-aware).
memory_usage() {
    awk '
        /^MemTotal/     { total = $2 }
        /^MemAvailable/ { avail = $2 }
        END {
            if (total <= 0 || avail == "") { print "N/A"; exit }
            printf "%.1f", (total - avail) * 100 / total
        }' /proc/meminfo
}

# Disk utilization for the given filesystem path.
disk_usage() {
    local pct
    pct=$(df -P "$DISK_PATH" 2>/dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }')
    if [[ -z "$pct" ]]; then
        echo "N/A"
    else
        echo "${pct}.0"
    fi
}

CPU=$(cpu_usage)
MEM=$(memory_usage)
DISK=$(disk_usage)

# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------

STATUS="HEALTHY"
REASONS=()

metric_line() {
    local label="$1" value="$2"
    printf "  %-8s %6s%% utilized\n" "$label" "$value"
}

metric_reason() {
    local label="$1" value="$2"
    if [[ "$value" == "N/A" ]]; then
        echo "  $label: could not be measured, so it was not counted toward the verdict."
        return
    fi
    if (( $(awk -v v="$value" -v t="$THRESHOLD" 'BEGIN { print (v > t) }') )); then
        echo "  $label is at ${value}% utilization, which is above the ${THRESHOLD}% threshold."
    else
        echo "  $label is at ${value}% utilization, which is within the ${THRESHOLD}% threshold."
    fi
}

check_metric() {
    local label="$1" value="$2"
    [[ "$value" == "N/A" ]] && return 0
    if (( $(awk -v v="$value" -v t="$THRESHOLD" 'BEGIN { print (v > t) }') )); then
        STATUS="UNHEALTHY"
        REASONS+=("$label is at ${value}% utilization, above the ${THRESHOLD}% threshold.")
    fi
}

check_metric "CPU" "$CPU"
check_metric "Memory" "$MEM"
check_metric "Disk" "$DISK"

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

echo "=============================================="
echo " VM Health Report ($(hostname), $(date '+%Y-%m-%d %H:%M:%S'))"
echo " Threshold: any metric above ${THRESHOLD}% => UNHEALTHY"
echo "----------------------------------------------"
metric_line "CPU" "$CPU"
metric_line "Memory" "$MEM"
metric_line "Disk" "$DISK" "(filesystem: $DISK_PATH)"
echo "----------------------------------------------"
echo " Health status: $STATUS"
echo "=============================================="

if $EXPLAIN; then
    echo
    echo " Explanation:"
    metric_reason "CPU" "$CPU"
    metric_reason "Memory" "$MEM"
    metric_reason "Disk" "$DISK"
    echo
    if [[ "$STATUS" == "HEALTHY" ]]; then
        echo " The VM is HEALTHY because none of the three metrics exceed ${THRESHOLD}% utilization."
    else
        echo " The VM is UNHEALTHY because:"
        for r in "${REASONS[@]}"; do
            echo "  - $r"
        done
    fi
fi

# Exit codes: 0 = healthy, 1 = unhealthy (handy for cron/monitoring jobs).
[[ "$STATUS" == "HEALTHY" ]] && exit 0 || exit 1
