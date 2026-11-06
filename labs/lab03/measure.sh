#!/usr/bin/env bash
# TE 578/778 - Lab 3: measure HTTP response time through the service chain
# Topology: see lab03/topology.md, diagrams "Lab 3 - service chain" and "Lab 3 - chain with vMON".
# usage: bash measure.sh <label> [requests] [container] [url]
#   bash measure.sh chain-2vnf 200
#   bash measure.sh baseline   200 vlb http://web1/      # 0 VNFs: LB talks to web1 directly
# Prints one CSV line: label,n_ok,mean_ms,p50_ms,p95_ms,max_ms,errors   (also appended to results.csv)
LABEL=${1:-run}; N=${2:-200}; FROM=${3:-client}; URL=${4:-http://10.10.1.2/}
RAW=$(mktemp)

docker exec "$FROM" sh -c "
  for i in \$(seq $N); do
    curl -s -o /dev/null -m 5 -w '%{http_code} %{time_total}\n' $URL || true
  done" > "$RAW"

ERR=$(awk '$1 != 200' "$RAW" | wc -l)
[ -f results.csv ] || echo "label,n_ok,mean_ms,p50_ms,p95_ms,max_ms,errors" > results.csv
awk '$1 == 200 { printf "%.3f\n", $2 * 1000 }' "$RAW" | sort -n |
awk -v label="$LABEL" -v err="$ERR" '
  { t[NR] = $1; sum += $1 }
  END {
    if (NR == 0) { printf "%s,0,,,,,%d\n", label, err; exit }
    i50 = int(NR * 0.50); if (i50 < 1) i50 = 1
    i95 = int(NR * 0.95); if (i95 < 1) i95 = 1
    printf "%s,%d,%.2f,%.2f,%.2f,%.2f,%d\n", label, NR, sum / NR, t[i50], t[i95], t[NR], err
  }' | tee -a results.csv
rm -f "$RAW"
