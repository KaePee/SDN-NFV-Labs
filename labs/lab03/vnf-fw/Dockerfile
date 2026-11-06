# TE 578/778 - Lab 3: a containerised firewall/NAT VNF (vFW)
# Topology: see lab03/topology.md, diagram "Lab 3 - service chain".
# The same image is reused later as a monitoring VNF (MODE=monitor).
FROM alpine:3.20

RUN apk add --no-cache iptables iproute2 tcpdump curl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Defaults - override them in docker-compose.yml (this is our "VNF descriptor")
ENV IN_NET=10.10.1. \
    OUT_NET=10.10.2. \
    NEXT_HOP=10.10.2.3 \
    SERVICE_PORT=80 \
    BLOCKED_SRC="" \
    MODE=firewall

ENTRYPOINT ["/entrypoint.sh"]
