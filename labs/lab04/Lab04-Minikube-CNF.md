# Lab 4 — Cloud-Native NFV on Minikube
### Kubernetes · CNFs · Services & kube-proxy · CNI (Calico) · NetworkPolicy · autoscaling

| | |
|---|---|
| **Course** | TE 578/778 — SDN & NFV |
| **Learning outcomes** | LO11 (cloud-native NFV on Kubernetes: CNI, NetworkPolicy, service concepts), LO4 (VNF lifecycle) |
| **Core (in class)** | ≈ 35 min — Parts A–D (check-off in Part D) |
| **Extended (take-home)** | ≈ 2–3 h — Parts E–F + research extension |
| **Files** | `manifests/00…50-*.yaml`, `probe.sh`, `check_policy.sh`, `topology.md` |
| **Prerequisite** | Lab 3 done; Docker works without sudo; ≥ 4 GB RAM free for the Minikube node |

---

## 1. What you will build

The Lab 3 service, re-built the **cloud-native** way: each network function becomes a **CNF** (a containerised network function managed by Kubernetes) and the platform takes over jobs you did by hand in Lab 3:

| Lab 3 (Docker Compose) | Lab 4 (Kubernetes) |
|---|---|
| vLB container (nginx round-robin) | **Service** `web` — kube-proxy load-balances across pods |
| vFW container (iptables in the VNF) | **gateway CNF** `gw` (nginx: rate limit, block `/admin`) + **NetworkPolicy** enforced by the CNI |
| `docker compose up` re-creates containers | **Deployment** with rolling updates, readiness probes, self-healing |
| manual scale-out (edit compose + nginx.conf) | `kubectl scale` / **HorizontalPodAutoscaler** |

> 📐 **Topology:** [`topology.md` → *Lab 4 - CNF service*](topology.md#lab-4---cnf-service).
> In words: one Minikube node running Calico. Namespace `nfv-lab` holds pods `client` (role=client) and `rogue` (role=rogue),
> the gateway Deployment `gw` behind Service `gw` (NodePort 30080), and the backend Deployment `web` (2 pods, scalable) behind ClusterIP Service `web`.
> Chain: client → svc/gw → gw pod → svc/web → web pods.
> The policy target state is drawn in [*Lab 4 - allowed flows after NetworkPolicy*](topology.md#lab-4---allowed-flows-after-networkpolicy).

---

## 2. Concepts refresher

**Kubernetes objects you'll use**

| Object | What it is | NFV analogy |
|---|---|---|
| Pod | one or more containers sharing a network namespace (one IP) | a VNFC instance |
| Deployment | desired state: "N replicas of this pod template" + update strategy | VNFM lifecycle logic |
| Service | stable virtual IP + DNS name in front of a set of pods (chosen by label) | virtual link + load balancer |
| ConfigMap | configuration mounted into pods | day-0/day-1 configuration |
| NetworkPolicy | allowed ingress/egress between pods, selected by labels | security policy of the forwarding graph |
| HPA | scales a Deployment on a metric (CPU) | auto-scaling rules in the VNFD |

**The Kubernetes network model:** every pod gets its own IP; every pod can reach every other pod **without NAT** — unless a NetworkPolicy says otherwise. A **CNI plugin** (here **Calico**) builds that network: a veth pair per pod (the same building block as Mininet and Docker), routes on the node, and **enforcement of NetworkPolicy**. Not every CNI enforces policy: with Minikube's default CNI your policies are silently ignored.

**How a Service works:** kube-proxy watches Services and EndpointSlices and writes **iptables DNAT rules** on every node: `ClusterIP:80 → one of the ready pod IPs`, chosen at random. It is the same DNAT trick as the Lab 3 vFW, generated automatically.

**CNFs in real telco networks** (5G core UPF/AMF, vRAN) usually also need **multiple interfaces** (Multus), **SR-IOV/DPDK** for performance and **CPU pinning/huge pages** (CPU Manager, Topology Manager). Our CNFs are simple HTTP functions so the concepts stay visible.

---

## 3. One-time setup (≈10 min, needs internet)

```bash
# Minikube (x86_64; on Apple Silicon/ARM use minikube-linux-arm64)
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube && rm minikube-linux-amd64

# kubectl: use the one bundled with Minikube
echo 'alias kubectl="minikube kubectl --"' >> ~/.bashrc && source ~/.bashrc
```

---

## PART A — Cluster and CNI (core, ~8 min)

**A1. Start a single-node cluster with Calico:**
```bash
minikube start --driver=docker --cni=calico --cpus=2 --memory=4g
kubectl get nodes -o wide
kubectl get pods -n kube-system           # wait until calico-node and calico-kube-controllers are Running
```

**A2. Look at the plumbing.** The Minikube node is itself a Docker container; `minikube ssh` opens a shell inside it.
```bash
minikube ssh -- ip -br link | grep cali     # one veth per pod (cali*), host side
minikube ssh -- ip route | grep cali        # a /32 route per pod -> Calico routes, no bridge
```

> **Checkpoint A:** Compare a Calico pod interface with (a) a Mininet host link and (b) a Docker bridge network from Lab 3. What is the same, and what is different (bridge vs routed)?

---

## PART B — Deploy the CNF service (core, ~10 min)

**B1. Apply the manifests in order:**
```bash
cd ~/labs/lab04
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/10-web-cnf.yaml -f manifests/20-gateway-cnf.yaml -f manifests/30-clients.yaml
kubectl get all -n nfv-lab -o wide
kubectl wait -n nfv-lab --for=condition=Ready pod --all --timeout=120s
```

Read `10-web-cnf.yaml` and `20-gateway-cnf.yaml` while the images pull. Find the readiness probe, the rolling-update strategy, the resource requests and the gateway's nginx policy (`limit_req`, `/admin`, `X-Forwarded-For`).

**B2. Use the chain from the client pod:**
```bash
for i in 1 2 3 4; do kubectl exec -n nfv-lab client -- curl -s http://gw/; done
kubectl exec -n nfv-lab client -- curl -sI http://gw/ | grep -i x-chain
kubectl exec -n nfv-lab client -- curl -s http://gw/admin
```
Expected: `Served by web-<pod-hash>` alternating between the two web pods; an `X-Chain: gw -> svc/web -> 10.244.x.y:80` header; `blocked by gateway CNF` for `/admin`.

**B3. The rate limit (10 req/s per client, burst 20):**
```bash
kubectl exec -n nfv-lab client -- sh -c \
  'for i in $(seq 60); do curl -s -o /dev/null -w "%{http_code}\n" http://gw/ & done; wait' | sort | uniq -c
```
Expect a mix of `200` and `429` (Too Many Requests).

**B4. From outside the cluster (NodePort):**
```bash
curl -s http://$(minikube ip):30080/
```

**B5. How does a Service balance load?**
```bash
kubectl get endpointslices -n nfv-lab
minikube ssh -- sudo iptables -t nat -L KUBE-SERVICES -n | grep nfv-lab
# follow the KUBE-SVC-... chain for nfv-lab/web:
minikube ssh -- sudo iptables -t nat -L KUBE-SVC-XXXXXXXXXXXXXXXX -n     # paste the chain name
```
You should see one rule per endpoint, with `statistic mode random probability 0.50000000000`, each jumping to a `KUBE-SEP-…` chain that DNATs to a pod IP.
(If the grep finds nothing, your kube-proxy may be in nftables mode: `minikube ssh -- sudo nft list ruleset | grep -A3 nfv-lab`.)

> **Checkpoint B:** (1) Which component does the job of Lab 3's vLB, and where does it run? (2) Why does a 2-endpoint Service need `probability 0.5` on the first rule but none on the second? Derive the probabilities for 3 endpoints.

---

## PART C — Lifecycle the Kubernetes way (core, ~10 min)

Keep a probe running in a **second terminal** for each step: `bash probe.sh 100 0.1` (100 requests through the chain, then a count of HTTP codes).

| Operation | Command (terminal 1) | Record from `probe.sh` |
|---|---|---|
| **Heal** (pod crash) | `kubectl delete pod -n nfv-lab -l app=web --wait=false` | non-200 count; time until `kubectl get pods` shows 2 Ready again |
| **Scale out** | `kubectl scale deploy/web -n nfv-lab --replicas=4` | which pods answer (`curl` a few times) |
| **Rolling update** | `kubectl rollout restart deploy/web -n nfv-lab` then `kubectl rollout status deploy/web -n nfv-lab` | non-200 count |
| **Scale in** | `kubectl scale deploy/web -n nfv-lab --replicas=2` | non-200 count |

The update sequence is drawn in [*Lab 4 - rolling update*](topology.md#lab-4---rolling-update).

> **Analysis C:** Compare with Lab 3 Part E, where re-creating the vFW cost ~3 failed requests out of 60. Which Kubernetes features make the rolling update hitless (look at `maxUnavailable`, `maxSurge`, `readinessProbe`)? Why can deleting **all** web pods at once still fail a few requests? What would change if `web` were *stateful* like the Lab 3 firewall?

---

## PART D — Enforce the chain with NetworkPolicy (core, ~10 min) — **check-off**

**D1. Before any policy:**
```bash
bash check_policy.sh
```
Everything is reachable, including `rogue → web` and `client → web` (skipping the gateway).

**D2. Zero trust — deny all ingress in the namespace:**
```bash
kubectl apply -f manifests/40-netpol-default-deny.yaml
bash check_policy.sh          # everything BLOCKED now (readiness probes still pass - why?)
```

**D3. Allow exactly the chain:**
```bash
kubectl apply -f manifests/41-netpol-chain.yaml
bash check_policy.sh
```
Expected matrix:
```
  client     -> http://gw/             HTTP 200
  client     -> http://gw/admin        HTTP 403
  client     -> http://web/            BLOCKED
  rogue      -> http://gw/             BLOCKED
  rogue      -> http://web/            BLOCKED
  gw-xxxxx   -> http://web/            HTTP 200
```

**D4. Predict, then test:** does `curl http://$(minikube ip):30080/` from your VM still work? Explain the result (hint: what source IP does the gw pod see for NodePort traffic, and what does the NetworkPolicy spec say about traffic from the node?).

> **Checkpoint D (core check-off):** show the three matrices (D1, D2, D3) and explain:
> 1. Who enforces the policy (which process, on which machine)? Would it be enforced with Minikube's default CNI?
> 2. NetworkPolicy selects pods **by label**. What could an attacker who is allowed to create pods in `nfv-lab` do? How would you prevent it (RBAC, admission policies, namespaces)?
> 3. Compare this with Lab 3's vFW: what can an L3/L4 NetworkPolicy *not* do that the gateway CNF does (rate limit, `/admin`)?

---

## PART E — Elastic scaling with the HPA (extended, ~30 min)

```bash
minikube addons enable metrics-server
kubectl top pods -n nfv-lab                     # may need ~1 min before metrics appear
kubectl apply -f manifests/50-hpa.yaml
kubectl get hpa -n nfv-lab
```

For this experiment, temporarily remove the policies so the load generator can hit `svc/web` directly (the gateway's rate limit would otherwise cap the load):
```bash
kubectl delete -f manifests/41-netpol-chain.yaml -f manifests/40-netpol-default-deny.yaml
kubectl run load -n nfv-lab --image=busybox:1.36 --restart=Never -- \
  sh -c 'for w in 1 2 3 4; do (while true; do wget -q -O /dev/null http://web; done) & done; wait'
kubectl get hpa -n nfv-lab -w        # watch TARGETS and REPLICAS (Ctrl-C to stop)
```
In another terminal: `watch -n2 kubectl top pods -n nfv-lab`.

Stop the load and watch it scale back in (the 30 s stabilisation window is in `50-hpa.yaml`):
```bash
kubectl delete pod load -n nfv-lab
kubectl get hpa -n nfv-lab -w
kubectl apply -f manifests/40-netpol-default-deny.yaml -f manifests/41-netpol-chain.yaml   # restore
```

Record a timeline: time of load start, time of each scale-out step, max replicas, time to scale back in.

> **Analysis E:** Why does the HPA react in steps of tens of seconds rather than instantly (metrics scrape interval, stabilisation windows)? Is that fast enough for (a) a flash crowd, (b) a LEO satellite pass where the traffic of a whole beam moves to a new gateway every few minutes? What would a *predictive* scaler need to know?

---

## PART F — Clean up

```bash
kubectl delete namespace nfv-lab
minikube stop            # or: minikube delete   (frees all disk space)
```

---

## 4. Research extension (choose one, ~1 page)

1. **VNF vs CNF, measured.** Using Lab 3 (Compose) and Lab 4 (Kubernetes), measure: time to instantiate the service, time to heal a failed backend, requests lost during an update, and memory footprint per function (`docker stats` vs `kubectl top`). Present a table and discuss the trade-offs.
2. **Placement across ground-station sites.** `minikube start --nodes 3 ...`, label the nodes as gateway sites (`kubectl label node minikube-m02 site=gw-accra`, …), and use `nodeAffinity` / `topologySpreadConstraints` so the web CNF is spread across sites while the gateway CNF stays at one site. Inject latency between nodes (`minikube ssh -n minikube-m02 -- sudo tc qdisc add dev eth0 root netem delay 20ms`) and measure the effect of placement. Relate it to VNF placement in a virtualised satellite ground segment (Day 6).
3. **Multi-interface CNFs.** Read about Multus and SR-IOV device plugins. Design (on paper, or in Minikube with the Multus addon if you're brave) a UPF-like CNF with separate N3/N6/management interfaces. Why doesn't the "one IP per pod" model fit telco functions?

---

## 5. Lab report checklist (Lab 4)

- [ ] Versions: `minikube version`, `kubectl version`, Calico version (`kubectl get ds -n kube-system calico-node -o jsonpath='{..image}'`)
- [ ] Checkpoint A answer, with `ip route` evidence
- [ ] Part B outputs, the kube-proxy rules you found and Checkpoint B
- [ ] Part C table and Analysis C (compared with Lab 3)
- [ ] Part D matrices, the D4 prediction vs result, Checkpoint D
- [ ] Part E timeline (a plot of replicas vs time is ideal) and Analysis E
- [ ] Research extension

---

## 6. Troubleshooting

| Problem | Fix |
|---|---|
| `minikube start` fails: not enough memory | lower `--memory=3g`, close other VMs, or give the VM more RAM |
| Pods stuck in `ImagePullBackOff` | network/proxy issue inside the node: `minikube ssh -- docker pull nginx:1.27-alpine`; or `minikube image load nginx:1.27-alpine` from the VM |
| Pods `Pending` | `kubectl describe pod ...` — usually CPU/memory requests vs node size |
| NetworkPolicies have no effect | cluster was started without `--cni=calico`: `minikube delete` and start again with it |
| `check_policy.sh` shows BLOCKED for everything after D3 | label typos: `kubectl get pods -n nfv-lab --show-labels` |
| `kubectl top`: `metrics not available yet` | wait 60 s after enabling metrics-server |
| HPA shows `<unknown>/50%` | pods need CPU **requests** (they have them) and metrics-server running |
| Apple Silicon | use `minikube-linux-arm64` inside an ARM Ubuntu VM; all images used are multi-arch |

---

