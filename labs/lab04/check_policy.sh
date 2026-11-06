#!/usr/bin/env bash
# TE 578/778 - Lab 4: connectivity matrix - who can reach what?
# Topology: see lab04/topology.md, diagram "Lab 4 - allowed flows after NetworkPolicy".
# Run before and after applying the NetworkPolicies and compare.
NS=nfv-lab
GW_POD=$(kubectl get pod -n $NS -l app=gw -o jsonpath='{.items[0].metadata.name}')
try() {  # try <from-pod> <url>
  # curl if the image has it, otherwise busybox wget (prints 200 or 000)
  code=$(kubectl exec -n $NS "$1" -- sh -c "if command -v curl >/dev/null; then curl -s -o /dev/null -m 3 -w '%{http_code}' $2; else wget -q -T 3 -O /dev/null $2 && echo 200 || echo 000; fi" 2>/dev/null)
  [ -z "$code" ] && code=000
  if [ "$code" = "000" ]; then r="BLOCKED"; else r="HTTP $code"; fi
  printf "  %-10s -> %-22s %s\n" "$1" "$2" "$r"
}
echo "Connectivity matrix (namespace $NS):"
try client http://gw/
try client http://gw/admin
try client http://web/
try rogue  http://gw/
try rogue  http://web/
try "$GW_POD" http://web/
