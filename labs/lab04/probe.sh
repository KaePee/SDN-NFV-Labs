#!/usr/bin/env bash
# TE 578/778 - Lab 4: send N requests from the client pod through the chain and
# count the HTTP status codes. Run it while you scale, roll out or delete pods.
# Topology: see lab04/topology.md, diagram "Lab 4 - CNF service".
#   bash probe.sh                 # 100 requests to http://gw, 0.1 s apart
#   bash probe.sh 300 0.05        # 300 requests, 50 ms apart
N=${1:-100}; GAP=${2:-0.1}; URL=${3:-http://gw}
kubectl exec -n nfv-lab client -- sh -c "
  for i in \$(seq $N); do
    curl -s -o /dev/null -m 2 -w '%{http_code}\n' $URL
    sleep $GAP
  done" | sort | uniq -c | awk '{printf "  %s x HTTP %s\n", $1, $2}'
