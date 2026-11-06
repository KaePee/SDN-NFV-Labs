# Lab 4 — Topology diagrams

Referenced by every file in `manifests/`, `probe.sh`, `check_policy.sh` and `Lab04-Minikube-CNF.md`.

## Lab 4 - CNF service

One Minikube node. Namespace `nfv-lab`. Kubernetes Services do the load balancing that the vLB
container did in Lab 3; the gateway CNF plays the role of the vFW.

```mermaid
flowchart LR
    laptop(["your VM<br/>curl $(minikube ip):30080"])
    subgraph node["Minikube node (Docker driver) · CNI: Calico"]
        subgraph ns["namespace nfv-lab"]
            client["pod client<br/>role=client"]
            rogue["pod rogue<br/>role=rogue"]
            svcgw(["svc/gw<br/>NodePort 30080"])
            gw["deploy/gw (1 pod)<br/>nginx: rate-limit,<br/>block /admin, XFF"]
            svcweb(["svc/web<br/>ClusterIP :80"])
            web1["web pod 1"]
            web2["web pod 2"]
            webn["web pod n<br/>(HPA, Part E)"]
        end
        kp["kube-proxy<br/>iptables DNAT"]
    end
    laptop --> svcgw
    client --> svcgw
    rogue -.-> svcgw
    svcgw --> gw
    gw --> svcweb
    svcweb --> web1 & web2 & webn
    kp -. programs .- svcgw & svcweb
```

## Lab 4 - allowed flows after NetworkPolicy

After `40-netpol-default-deny.yaml` + `41-netpol-chain.yaml` (Part D). Solid = allowed, crossed = denied.

```mermaid
flowchart LR
    client["client<br/>role=client"] -->|"TCP 80 ✔"| gw["gw<br/>app=gw"]
    gw -->|"TCP 80 ✔"| web["web<br/>app=web"]
    rogue["rogue<br/>role=rogue"] x--x|"✘"| gw
    rogue x--x|"✘"| web
    client x--x|"✘ (must go through gw)"| web
    node(["node / kubelet probes"]) -->|"always allowed"| gw & web
```

## Lab 4 - rolling update

What `kubectl rollout restart deploy/web` does with `maxSurge: 1, maxUnavailable: 0` and a readiness probe (Part C).

```mermaid
sequenceDiagram
    participant D as Deployment controller
    participant N as new pod
    participant O as old pod
    participant S as svc/web endpoints
    D->>N: create (surge +1)
    N-->>S: readiness probe OK → added to endpoints
    D->>O: terminate (only now)
    S-->>O: removed from endpoints
    Note over D,S: repeated pod by pod: capacity never drops below 2 ready pods
```
