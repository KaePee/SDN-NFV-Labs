#!/bin/sh
# TE 578/778 - Lab 3: vFW / vMON entrypoint
# Topology: see lab03/topology.md, diagrams "Lab 3 - service chain" and "Lab 3 - chain with vMON".
#
# Behaviour (controlled by environment variables):
#   IN_NET        prefix of the network traffic arrives on      e.g. 10.10.1.
#   OUT_NET       prefix of the network traffic leaves on       e.g. 10.10.2.
#   NEXT_HOP      IP of the next function in the chain          e.g. 10.10.2.3
#   SERVICE_PORT  the only TCP port this VNF lets through       e.g. 80
#   BLOCKED_SRC   space-separated source IPs to always drop     e.g. "10.10.1.66"
#   MODE          firewall | monitor  (monitor also prints every new HTTP flow)
set -e

# Docker does not guarantee eth0/eth1 ordering, so find interfaces by subnet
ifname_for() { ip -o -4 addr show | awk -v p="$1" 'index($4, p) == 1 {print $2; exit}'; }
IN_IF=$(ifname_for "$IN_NET")
OUT_IF=$(ifname_for "$OUT_NET")
MY_IP=$(ip -o -4 addr show dev "$IN_IF" | awk '{split($4,a,"/"); print a[1]}')

echo "[$(hostname)] MODE=$MODE  in=$IN_IF($MY_IP)  out=$OUT_IF  next_hop=$NEXT_HOP:$SERVICE_PORT"

# ---------------- clean slate ----------------
# Only touch our own rules. Do NOT flush the whole nat table: Docker keeps the
# rules for its embedded DNS server (127.0.0.11) there.
iptables -F; iptables -X
iptables -t nat -N VNF_PRE 2>/dev/null || iptables -t nat -F VNF_PRE
iptables -t nat -N VNF_POST 2>/dev/null || iptables -t nat -F VNF_POST
iptables -t nat -C PREROUTING -j VNF_PRE 2>/dev/null || iptables -t nat -I PREROUTING 1 -j VNF_PRE
iptables -t nat -C POSTROUTING -j VNF_POST 2>/dev/null || iptables -t nat -I POSTROUTING 1 -j VNF_POST

# ---------------- filter table ----------------
iptables -P FORWARD DROP                       # default-deny for transit traffic
iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
for src in $BLOCKED_SRC; do
  iptables -A FORWARD -s "$src" -j DROP
  echo "[$(hostname)] blocking source $src"
done
iptables -A FORWARD -i "$IN_IF" -o "$OUT_IF" -p tcp -d "$NEXT_HOP" --dport "$SERVICE_PORT" \
         -m conntrack --ctstate NEW -j ACCEPT
iptables -A FORWARD -j DROP                    # explicit rule so we can see its counter

# ---------------- nat table: this is what steers traffic down the chain -------
# Anything that hits MY_IP:SERVICE_PORT is rewritten towards the next hop ...
iptables -t nat -A VNF_PRE -i "$IN_IF" -d "$MY_IP" -p tcp --dport "$SERVICE_PORT" \
         -j DNAT --to-destination "$NEXT_HOP:$SERVICE_PORT"
# ... and source-NATed so the reply comes back through this VNF
iptables -t nat -A VNF_POST -o "$OUT_IF" -d "$NEXT_HOP" -j MASQUERADE

iptables -S
iptables -t nat -S VNF_PRE
iptables -t nat -S VNF_POST

if [ "$MODE" = "monitor" ]; then
  echo "[$(hostname)] monitor mode: logging new HTTP connections"
  exec tcpdump -l -n -i "$IN_IF" "tcp dst port $SERVICE_PORT and tcp[tcpflags] & tcp-syn != 0"
fi

# keep the container alive and react to 'docker stop' quickly
trap 'echo "[$(hostname)] stopping"; exit 0' TERM INT
while true; do sleep 3600 & wait $!; done
