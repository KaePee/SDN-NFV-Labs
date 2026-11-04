# Lab 1 — Topology diagrams

Referenced by `lab_topo.py`, `hub_13.py`, `learning_switch_13.py` and `Lab01-Mininet-Ryu.md`.
These diagrams render on GitHub/GitLab, in VS Code (Markdown Preview Mermaid Support) and in Obsidian.

## Lab 1 - topology

Three OpenFlow 1.3 switches in a line, two hosts per switch, one remote Ryu controller.
Edge labels give the **OpenFlow port number on the switch side** (fixed in `lab_topo.py`).

```mermaid
flowchart LR
    C[["Ryu controller<br/>127.0.0.1:6653"]]

    subgraph site1[" "]
        h1["h1<br/>10.0.0.1<br/>00:..:01"]
        h2["h2<br/>10.0.0.2<br/>00:..:02"]
    end
    subgraph site2[" "]
        h3["h3<br/>10.0.0.3<br/>00:..:03"]
        h4["h4<br/>10.0.0.4<br/>00:..:04"]
    end
    subgraph site3[" "]
        h5["h5<br/>10.0.0.5<br/>00:..:05"]
        h6["h6<br/>10.0.0.6<br/>00:..:06"]
    end

    s1{{"s1<br/>dpid 1"}}
    s2{{"s2<br/>dpid 2"}}
    s3{{"s3<br/>dpid 3"}}

    h1 ---|"s1:p1"| s1
    h2 ---|"s1:p2"| s1
    h3 ---|"s2:p1"| s2
    h4 ---|"s2:p2"| s2
    h5 ---|"s3:p1"| s3
    h6 ---|"s3:p2"| s3
    s1 ===|"s1:p3 — s2:p3<br/>core link (--bw/--delay/--loss)"| s2
    s2 ===|"s2:p4 — s3:p3<br/>core link"| s3

    C -.-|OpenFlow 1.3| s1
    C -.-|OpenFlow 1.3| s2
    C -.-|OpenFlow 1.3| s3
```

## Lab 1 - loop variant

`sudo python3 lab_topo.py --loop` adds a direct s1–s3 link (port 4 on both), creating a physical loop (Part F).

```mermaid
flowchart LR
    s1{{"s1"}} ===|"p3 — p3"| s2{{"s2"}}
    s2 ===|"p4 — p3"| s3{{"s3"}}
    s1 -.-|"p4 — p4 (--loop)<br/>broadcast storm without STP"| s3
```

## Lab 1 - reactive flow setup

What happens on the wire for the **first** packet of `h1 ping h3` with a learning switch (Part C).

```mermaid
sequenceDiagram
    autonumber
    participant h1
    participant s1 as s1 (OVS)
    participant C as Ryu controller
    participant s2 as s2 (OVS)
    participant h3
    Note over s1,C: handshake: HELLO, FEATURES_REQUEST/REPLY,<br/>FLOW_MOD table-miss (prio 0 → CONTROLLER)
    h1->>s1: ARP who-has 10.0.0.3 (broadcast)
    s1->>C: PACKET_IN (no match → table-miss)
    C->>C: learn h1 is on s1:p1
    C->>s1: PACKET_OUT (FLOOD)
    s1->>s2: ARP (flooded)
    s2->>C: PACKET_IN
    C->>s2: PACKET_OUT (FLOOD)
    s2->>h3: ARP
    h3->>s2: ARP reply (to h1)
    s2->>C: PACKET_IN
    C->>s2: FLOW_MOD (in_port=1, src=h3, dst=h1 → p3)
    C->>s2: PACKET_OUT (p3)
    Note over h1,h3: ICMP echo follows the same pattern once,<br/>later packets match the installed flows and never reach the controller
```
