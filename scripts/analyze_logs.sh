#!/usr/bin/env bash
# Analyze an access log in the format:
#   ISO8601 HTTP_STATUS METHOD URL duration_ms=N
# Usage: scripts/analyze_logs.sh <path-to-access.log>
# Exit codes: 0 = ok, 1 = missing/unreadable file, 2 = usage error.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <path-to-access.log>" >&2
  exit 2
fi

LOG_FILE="$1"

if [ ! -f "$LOG_FILE" ] || [ ! -r "$LOG_FILE" ]; then
  echo "ERROR: log file not found or not readable: $LOG_FILE" >&2
  exit 1
fi

total=$(awk 'NF > 0' "$LOG_FILE" | wc -l | tr -d ' ')
c4xx=$(awk '$2 ~ /^4[0-9][0-9]$/' "$LOG_FILE" | wc -l | tr -d ' ')
c5xx=$(awk '$2 ~ /^5[0-9][0-9]$/' "$LOG_FILE" | wc -l | tr -d ' ')

if [ "$total" -gt 0 ]; then
  rate=$(awk -v e="$c5xx" -v t="$total" 'BEGIN { printf "%.2f", (e / t) * 100 }')
else
  rate="0.00"
fi

echo "Log file        : $LOG_FILE"
echo "Total requests  : $total"
echo "HTTP 4xx        : $c4xx"
echo "HTTP 5xx        : $c5xx"
echo "HTTP 5xx rate   : ${rate}%"
echo "Top 3 routes    :"
awk 'NF > 0 { print $4 }' "$LOG_FILE" | sort | uniq -c | sort -rn | head -3 \
  | awk '{ printf "  %s requests  %s\n", $1, $2 }'
