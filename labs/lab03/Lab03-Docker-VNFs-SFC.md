# Lab 3 — Docker-based VNF Deployment and Service Function Chaining
### Docker · Docker Compose · iptables · nginx · tcpdump

| | |
|---|---|
| **Course** | TE 578/778 — SDN & NFV |
| **Learning outcomes** | LO4 (ETSI NFV concepts, VNF descriptors, SFC; deploy containerised VNFs with Docker) |
| **Core (in class)** | ≈ 35 min — Parts A–C |
| **Extended (take-home)** | ≈ 2–3 h — Parts D–F + research extension |
| **Files** | `docker-compose.yml`, `docker-compose.vmon.yml`, `vnf-fw/` (Dockerfile + entrypoint.sh), `vnf-lb/nginx.conf`, `client/Dockerfile`, `web/`, `measure.sh` |
| **Prerequisite** | Docker works without sudo (`docker run --rm hello-world`); images pre-pulled (Lab 0 §5) |

---

## 1. What you will build

A small **network service** made of containerised network functions, chained so that user traffic *must* pass through a firewall, then a load balancer, before reaching the servers:

> 📐 **Topology:** [`topology.md` → *Lab 3 - service chain*](topology.md#lab-3---service-chain).
> In words: three Docker networks. **access** 10.10.1.0/24 holds client (.10), rogue (.66) and the vFW (.2);
> **core** 10.10.2.0/24 joins the vFW (.2) and the vLB (.3); **srv** 10.10.3.0/24 joins the vLB (.3) and web1/web2 (.11/.12).
> Service chain (VNF forwarding graph): client → vFW → vLB → {web1, web2}.

- **vFW** (custom image you build): stateful firewall, blacklist and only TCP/80 allowed; it is also the chain's **entry point**, so clients only know `10.10.1.2`.
- **vLB** (nginx): HTTP load balancer across two web servers.
- **rogue**: a blacklisted client, to prove the policy works.

In Part D you'll **insert a third VNF (vMON) into the running chain** by changing one parameter.

---

## 2. Concepts refresher

### 2.1 Mapping ETSI NFV onto what we use

(diagram: [*Lab 3 - ETSI mapping*](topology.md#lab-3---etsi-mapping))

| ETSI NFV concept | In this lab |
|---|---|
| VNF | a container (vFW, vLB, vMON) |
| VNF package / image | Docker image built from a `Dockerfile` |
| **VNFD** (descriptor: image, resources, interfaces, config) | `Dockerfile` + the service's block in `docker-compose.yml` (`environment`, `cap_add`, `networks`) |
| Virtual link (VLD) | a Docker network (`access`, `core`, `srv`) = a Linux bridge plus veth pairs, the same plumbing Mininet uses |
| **NSD** (network service descriptor) | the whole `docker-compose.yml` |
| **VNFFG** (forwarding graph / chain) | how the vFW → vLB → web next hops are wired (env `NEXT_HOP`, nginx `upstream`) |
| NFVI + VIM | your Linux host + Docker Engine |
| VNFM / NFVO (lifecycle, orchestration) | `docker compose` (a very simple one) |

### 2.2 How do packets get "steered" through a chain?

| Technique | How | Used in |
|---|---|---|
| **Addressing / NAT** | each function is the client's destination; it rewrites the destination (DNAT) to the next function | **this lab** (vFW → vLB) and proxies (vLB → web) |
| Policy routing | next-hop routes / VRFs point to the next function | classic data centres |
| **SDN steering** | OpenFlow rules match the flow and forward it to the VNF's port | **Lab 5** |
| Encapsulation | NSH (RFC 8300) or SRv6 carries the service path in the packet | carrier SFC |

### 2.3 Why the vFW uses DNAT *and* SNAT

```
client 10.10.1.10 ──▶ dst 10.10.1.2:80          (client only knows the vFW)
vFW PREROUTING  DNAT ▶ dst 10.10.2.3:80          (steer to next hop)
vFW POSTROUTING SNAT ▶ src 10.10.2.2              (so the reply comes BACK through the vFW)
vLB sees: 10.10.2.2 → 10.10.2.3
```
Without SNAT the vLB would reply straight to 10.10.1.10 via its default gateway, bypassing the vFW. The firewall's connection tracking would never see the reply, and the client would drop it as unexpected.

---

## PART A — Build the VNF images (core, ~8 min)

```bash
cd ~/labs/lab03
tree .            # or: find . -type f
```

**A1. Read the vFW "VNF package":**

`vnf-fw/Dockerfile`, a minimal image with the tools a firewall needs:
```dockerfile
FROM alpine:3.20
RUN apk add --no-cache iptables iproute2 tcpdump curl
COPY entrypoint.sh /entrypoint.sh
ENV IN_NET=10.10.1. OUT_NET=10.10.2. NEXT_HOP=10.10.2.3 SERVICE_PORT=80 BLOCKED_SRC="" MODE=firewall
ENTRYPOINT ["/entrypoint.sh"]
```

`vnf-fw/entrypoint.sh` turns those parameters into rules:
1. finds its interfaces **by subnet** (Docker doesn't guarantee `eth0`/`eth1` order);
2. `FORWARD` default **DROP**; allow `ESTABLISHED,RELATED`; drop `BLOCKED_SRC`; allow only `NEW` TCP to `NEXT_HOP:SERVICE_PORT`;
3. **DNAT** `MY_IP:80 → NEXT_HOP:80`, **MASQUERADE** towards the next hop;
4. in `MODE=monitor`, also prints every new connection (`tcpdump`).

> The same image with different environment variables becomes a different VNF (firewall or monitor). That is the idea behind VNF descriptors and day-0 configuration.

**A2. Build:**
```bash
docker compose build
docker images | grep lab3
```
Expected: `lab3/vnf-fw:1.0` and `lab3/client:1.0`.

---

## PART B — Deploy the network service (core, ~7 min)

```bash
docker compose up -d
docker compose ps
```
Expected: `client  rogue  vfw  vlb  web1  web2` all `Up`.

**B1. Inspect the virtual links:**
```bash
docker network ls | grep lab3
docker network inspect lab3-sfc_core --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
ip link show type bridge | grep br-          # each network is a Linux bridge on your VM
```

**B2. Inspect the vFW's day-0 configuration:**
```bash
docker logs vfw
```
Expected (abridged):
```
[vfw] MODE=firewall  in=eth0(10.10.1.2)  out=eth1  next_hop=10.10.2.3:80
[vfw] blocking source 10.10.1.66
-P FORWARD DROP
-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -s 10.10.1.66/32 -j DROP
-A FORWARD -d 10.10.2.3/32 -i eth0 -o eth1 -p tcp -m tcp --dport 80 -m conntrack --ctstate NEW -j ACCEPT
-A FORWARD -j DROP
-A VNF_PRE -d 10.10.1.2/32 -i eth0 -p tcp -m tcp --dport 80 -j DNAT --to-destination 10.10.2.3:80
-A VNF_POST -d 10.10.2.3/32 -o eth1 -j MASQUERADE
```
(Your `eth0`/`eth1` may be swapped. The script handles that.)

---

## PART C — Test the chain (core, ~15 min)

**C1. Normal user through the chain, run 4 times:**
```bash
for i in 1 2 3 4; do docker exec client curl -s http://10.10.1.2/; done
```
Expected (round-robin):
```
<h1>Served by web1</h1>
<h1>Served by web2</h1>
<h1>Served by web1</h1>
<h1>Served by web2</h1>
```
```bash
docker exec client curl -sI http://10.10.1.2/ | grep -i x-chain
# X-Chain: vFW -> vLB -> 10.10.3.11:80
```

**C2. Policy tests.** Predict each result before running it:

| # | Command | Expected | Why? (fill in) |
|---|---|---|---|
| 1 | `docker exec rogue curl -s -m 3 http://10.10.1.2/` | timeout (exit 28) | |
| 2 | `docker exec client curl -s -m 3 http://10.10.1.2:8080/` | connection refused (exit 7) | |
| 3 | `docker exec client curl -s -m 3 http://10.10.2.3/` (skip the vFW) | timeout | |
| 4 | `docker exec client ping -c 2 10.10.1.2` | replies | |

**C3. Evidence from the VNFs themselves:**
```bash
docker exec vfw iptables -L FORWARD -v -n         # per-rule packet counters
docker logs vlb | tail -4                          # who does the vLB think the client is?
docker exec client curl -s http://10.10.1.2/lb-status
```
Reference counters after the tests:
```
 pkts bytes target  prot  in   out   source       destination
   45  4252 ACCEPT  0     *    *     0.0.0.0/0    0.0.0.0/0     ctstate RELATED,ESTABLISHED
    3   180 DROP    0     *    *     10.10.1.66   0.0.0.0/0
    5   300 ACCEPT  6     eth0 eth1  0.0.0.0/0    10.10.2.3     tcp dpt:80 ctstate NEW
```
vLB log: `10.10.2.2 -> 10.10.3.11:80 "GET / HTTP/1.1" 200`. The vLB sees the **vFW** as the client.

> **Checkpoint C (core check-off):**
> 1. Show C1 round-robin output, the rogue timeout and the vFW counters.
> 2. Fill in the "Why?" column. In particular: why is #2 *refused* (fast) but #1 a *timeout* (slow)? Why does #3 fail even though the client's VM can route to 10.10.2.0/24?
> 3. Why does the vLB log show `10.10.2.2` instead of `10.10.1.10`? Name one thing that breaks because of this, and one standard fix (hint: an HTTP header).

---

## PART D — Re-chaining a live service: insert a monitoring VNF (extended, ~25 min)

New requirement from "the operator": every new connection must be logged by a monitoring function placed **between the firewall and the load balancer**.

```
before:  client → vFW → vLB → web
after :  client → vFW → vMON → vLB → web
```
(diagram: [*Lab 3 - chain with vMON*](topology.md#lab-3---chain-with-vmon))

`docker-compose.vmon.yml` is an overlay that (a) adds `vmon`, the **same image** as vFW but with `MODE=monitor` on the core network at `10.10.2.4`, and (b) changes **one** parameter of vFW: `NEXT_HOP: 10.10.2.4`.

**D1. Apply the change, with traffic running in a second terminal:**
```bash
# terminal 2: continuous probe
while true; do docker exec client curl -s -o /dev/null -m 1 -w "%{http_code} " http://10.10.1.2/; sleep 0.2; done

# terminal 1: re-chain
docker compose -f docker-compose.yml -f docker-compose.vmon.yml up -d
```
Compose creates `vmon` and **re-creates** `vfw` with the new next hop. Count the non-200 responses in terminal 2.

**D2. Verify the new path:**
```bash
docker logs vmon | tail -4
docker logs vlb  | tail -2
```
Reference:
```
[vmon] MODE=monitor  in=eth0(10.10.2.4)  out=eth0  next_hop=10.10.2.3:80
IP 10.10.2.2.46506 > 10.10.2.4.80: Flags [S] ...      <- arriving from the vFW
IP 10.10.2.4.46506 > 10.10.2.3.80: Flags [S] ...      <- leaving towards the vLB, NAT-ed
vlb: 10.10.2.4 -> 10.10.3.12:80 "GET / HTTP/1.1" 200    <- vLB now sees the vMON as its client
```

**D3. Remove the vMON again (roll back the chain):**
```bash
docker compose up -d --remove-orphans
```

> **Analysis D:**
> 1. How many service interruptions (non-200s) did re-chaining cause, and why? (Which container was restarted?) How would you re-chain **without** interruption? Think make-before-break: start the new path, switch traffic, then remove the old one.
> 2. vMON is "one-armed": it receives and sends on the same interface. Why does that still work here? What would a *transparent* (bump-in-the-wire) monitor need instead?
> 3. With NAT-based chaining, each VNF must know the next hop's address. Why does that couple the VNFs, and how do SDN steering (Lab 5) and NSH remove that coupling?

---

## PART E — VNF lifecycle management (extended, ~30 min)

Perform each ETSI VNFM operation with Docker and record the evidence:

| ETSI lifecycle op | What to do | Evidence to record |
|---|---|---|
| **Instantiate** | `docker compose up -d` | `docker compose ps`; time until the first 200 |
| **Query / monitor** | `docker stats --no-stream`; `curl .../lb-status` | CPU/memory per VNF; active connections |
| **Heal** (failure of a backend) | `docker stop web1`, then send 6 requests | all 200? which server answered? nginx `max_fails` behaviour in `docker logs vlb` |
| **Heal** (automatic) | add `restart: unless-stopped` to `web1`, `docker compose up -d`, then `docker exec web1 nginx -s stop` (the main process exits) | does Docker bring it back? how long? |
| **Scale out** | add a `web3` service (10.10.3.13, its own `web3.html`) to the compose file, add `server web3:80;` to `nginx.conf`, then `docker compose up -d web3 && docker compose restart vlb` | responses now cycle web1/web2/web3 |
| **Update** (reconfigure) | change `BLOCKED_SRC` to also block `10.10.1.10`, `docker compose up -d vfw`, probe as in D1 | downtime (count non-200s); new rules in `docker logs vfw` |
| **Terminate** | `docker compose down` | all containers and networks removed |

Reference (rolling update of the vFW, 60 probes every 0.1 s): **3 failed requests** while the container was re-created, all others 200.

> Tip: if a change to the bind-mounted `nginx.conf` seems ignored, restart the container (`docker compose restart vlb`). Some editors replace the file, and a single-file bind mount keeps pointing at the old one.

> **Analysis E:** Compose re-creates a container for *any* change to its descriptor. Which operations caused downtime? Propose how a real VNFM (or Kubernetes, Lab 4) avoids it: rolling updates, readiness checks, redundancy (N+1 vFW behind a VIP), state replication for a stateful firewall's conntrack table.

---

## PART F — How much does each VNF cost? (extended, ~30 min) — towards NTN

`measure.sh` sends N HTTP requests from a container and reports mean, p50, p95 and max response time (and appends to `results.csv`).

```bash
docker compose up -d                                 # base chain
bash measure.sh lb-only     200 vfw http://10.10.2.3/   # 1 VNF: vLB only (sent from inside the vFW)
bash measure.sh chain-fw-lb 200                          # 2 VNFs: client → vFW → vLB
docker compose -f docker-compose.yml -f docker-compose.vmon.yml up -d
bash measure.sh chain-fw-mon-lb 200                      # 3 VNFs
cat results.csv
```

Reference run (a laptop VM; your absolute numbers will differ):
```
label,n_ok,mean_ms,p50_ms,p95_ms,max_ms,errors
lb-only,100,1.38,0.65,0.97,71.79,0          <- note the 72 ms first-request outlier
chain-fw-lb,100,0.69,0.64,0.93,1.58,0
chain-fw-mon-lb,100,0.80,0.76,1.05,1.81,0
```

**F2. Put a satellite link in the chain.** Make the vFW → next-hop link behave like a GEO feeder link (≈ 270 ms one-way) or a LEO link (≈ 15 ms):
```bash
IF=$(docker exec vfw sh -c "ip -o -4 addr | awk '/10\.10\.2\./{print \$2}'")
docker exec vfw tc qdisc add dev $IF root netem delay 270ms        # GEO-like
bash measure.sh geo-backhaul 50
docker exec vfw tc qdisc change dev $IF root netem delay 15ms 3ms  # LEO-like, with jitter
bash measure.sh leo-backhaul 50
docker exec vfw tc qdisc del dev $IF root
```

> **Analysis F:**
> 1. Why do we report p50 and p95, not only the mean? What caused the 72 ms outlier, and how should you handle warm-up in your measurements?
> 2. What is the incremental latency per VNF? Is it significant compared with a LEO RTT (≈ 25–40 ms) or a GEO RTT (≈ 540 ms)?
> 3. With 270 ms one-way delay on the vFW → vLB hop, the HTTP response time is much more than 540 ms. Count the round trips (TCP handshake + request/response) to explain it. Where in an NTN chain should the vLB and the web servers live (ground station, MEC at the gateway, on board a regenerative satellite) to avoid this?

---

## 3. Research extension (choose one, ~1 page)

1. **VNF placement in an NTN.** Model a chain (vFW → vLB → app) with three candidate sites: *on-board* (low latency, scarce CPU and energy), *gateway MEC* (medium), *cloud* (high latency, unlimited resources). Use `tc netem` delays for the links and Docker `--cpus` limits for capacity. Measure response time for different placements and formulate the placement problem (decision variables, objective, constraints). Compare with the formulations surveyed in Mijumbi et al. (2016).
2. **Stateful VNF migration.** The vFW keeps conntrack state. What happens to an ongoing long download (`curl --limit-rate 50k`) when you re-create the vFW? Propose and test a mitigation (e.g. `conntrack-tools` state sync between two vFWs, or connection draining). Relate it to satellite gateway handover.
3. **VNF density and performance isolation.** Run `docker stats` while generating load (`ab`/`hey` from the client). Add CPU limits to the vLB and find the knee of the latency curve. What does this say about NFVI dimensioning and the need for DPDK/SR-IOV (Day 3)?

---

## 4. Lab report checklist (Lab 3)

- [ ] Your mapping of each file and Compose element to ETSI NFV concepts (extend the table in §2.1)
- [ ] Checkpoint C: outputs and the completed "Why?" table
- [ ] Part D: probe output during re-chaining, vMON/vLB logs, Analysis D
- [ ] Part E: the lifecycle table filled with evidence, Analysis E
- [ ] Part F: `results.csv` with at least 3 repetitions per configuration, a plot (mean ± std or boxplot), Analysis F
- [ ] Research extension
- [ ] `docker compose down` at the end (no leftovers)

---

## 5. Troubleshooting

| Problem | Fix |
|---|---|
| `pull access denied for lab3/client` | Run `docker compose build` first (it is a local image) |
| `vfw` exits immediately | `docker logs vfw`. Missing `cap_add: NET_ADMIN`, or an IN_NET/OUT_NET prefix that matches no interface |
| `Pool overlaps with other one on this address space` | Another Docker network uses 10.10.x.0/24: `docker network prune`, or change the subnets in the compose file (and the env/IPs) |
| `vlb` exits: `host not found in upstream "web1:80"` | web1 isn't running. `docker compose up -d web1 web2`, then `docker compose restart vlb` |
| Changes to `nginx.conf` ignored | `docker compose restart vlb` (see the tip in Part E) |
| `tc: command not found` / `Operation not permitted` in vfw | Rebuild the image (`iproute2` provides `tc`); vfw needs `NET_ADMIN` |
| Apple Silicon: slow builds | Normal on first build; alpine and nginx images are multi-arch |

---

