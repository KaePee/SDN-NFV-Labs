# Lab 1 — SDN Topology Creation and Flow Control
### Mininet · Open vSwitch · Ryu · Wireshark

| | |
|---|---|
| **Course** | TE 578/778 — SDN & NFV |
| **Learning outcomes** | LO1 (control/data-plane separation), LO2 (Mininet topologies, Ryu with OpenFlow 1.3) |
| **Core (in class)** | ≈ 35 min — Parts A–C |
| **Extended (take-home)** | Parts D–F + research extension |
| **Files** | `lab_topo.py`, `hub_13.py`, `learning_switch_13.py`, `simple_network.py` |
| **Before you start** | `bash ~/labs/check_env.sh` shows 0 FAIL (Lab 0) |

---

## 1. What you will build

A software-defined network with **3 OpenFlow switches and 6 hosts**, controlled by a **Ryu** controller. You will watch, packet by packet, how the controller learns the network and programs the switches. Then you'll write two controller apps of your own and break the network on purpose.

> 📐 **Topology:** [`topology.md` → *Lab 1 - topology*](topology.md#lab-1---topology).
> In words: s1–s2–s3 in a line; h1, h2 on s1 (ports 1, 2); h3, h4 on s2; h5, h6 on s3; core links s1:p3–s2:p3 and s2:p4–s3:p3.
> Host *n* has IP `10.0.0.n` and MAC `00:00:00:00:00:0n`. One Ryu controller at `127.0.0.1:6653` controls all three switches.
> The port numbers are fixed in `lab_topo.py` so everyone's flow tables look the same.
> The Packet-In/Flow-Mod exchange of Part C is drawn in [*Lab 1 - reactive flow setup*](topology.md#lab-1---reactive-flow-setup).

---

## 2. Concepts you need (5-minute refresher)

**Mininet** builds a whole network inside one Linux kernel:
- each **host** is an ordinary process inside its own **network namespace** (its own interfaces, routes and ARP table);
- each **link** is a **veth pair**, a virtual cable with two ends;
- each **switch** is an **Open vSwitch (OVS)** bridge that can be controlled over OpenFlow;
- link properties (bandwidth, delay, loss) are emulated with Linux **tc/netem** (`TCLink`).

**An OpenFlow switch on its own knows nothing.** In OpenFlow 1.3, a packet that matches no flow entry is **dropped**. A controller makes the network work by installing flows, either:
- **reactively:** an unknown packet is sent up as a **Packet-In**; the controller decides, sends a **Flow-Mod** (install a rule) and/or a **Packet-Out** (send this one packet), or
- **proactively:** rules are installed before traffic arrives (Lab 2).

**OpenFlow messages**

| Type # | Message | Direction | Meaning |
|---|---|---|---|
| 0 | `OFPT_HELLO` | both | version negotiation |
| 5 / 6 | `FEATURES_REQUEST` / `_REPLY` | C→S / S→C | "who are you?" (datapath ID, number of tables, capabilities) |
| 10 | `PACKET_IN` | S→C | "I don't know what to do with this packet" |
| 12 | `PORT_STATUS` | S→C | a port was added, removed or changed |
| 13 | `PACKET_OUT` | C→S | "send this packet out of port X" |
| 14 | `FLOW_MOD` | C→S | add, modify or delete a flow entry |
| 18 / 19 | `MULTIPART_REQUEST` / `_REPLY` | C→S / S→C | statistics, port descriptions |
| 2 / 3 | `ECHO_REQUEST` / `_REPLY` | both | keep-alive |

---

## PART A — Mininet warm-up

**A1. Start a tiny network** (one switch, three hosts, OVS acting as a plain learning bridge, no controller):

```bash
sudo mn --topo single,3 --mac --switch ovsbr --controller none
```

**A2. Explore it from the `mininet>` prompt:**

```
mininet> help                 # all CLI commands
mininet> nodes                # list nodes
mininet> net                  # who is connected to whom
mininet> dump                 # IPs and PIDs
mininet> h1 ip addr           # run any Linux command "inside" h1
mininet> h1 ping -c 3 h2      # hostnames are replaced by their IPs
mininet> pingall
mininet> iperf h1 h3          # TCP throughput test
mininet> sh ovs-vsctl show    # 'sh' runs a command on the VM itself
```

**A3. Prove that hosts are just processes in namespaces.** In a *second terminal*:

```bash
ps -ef | grep "mininet:h1"                 # find the PID of h1's shell
sudo nsenter -t <PID> -n ip addr           # enter h1's network namespace
ip link | grep s1-eth                      # the switch-side veth ends live in the root namespace
```

> **Checkpoint A:** Explain in two sentences why Mininet can emulate a network of hundreds of hosts on a laptop.

**A4. Exit and clean up:**

```
mininet> exit
$ sudo mn -c        # always do this after a crash
```

---

## PART B — A custom topology with the Python API

Open `lab_topo.py` and read the `LabTopo.build()` method. The key API calls:

```python
s1 = self.addSwitch("s1", protocols="OpenFlow13")
h1 = self.addHost("h1", ip="10.0.0.1/24", mac="00:00:00:00:00:01")
self.addLink(h1, s1, port2=1)                         # host link, fixed switch port 1
self.addLink(s1, s2, port1=3, port2=3, **core)        # core link; core may hold bw/delay/loss
```

**B1. Start the topology with NO controller:**

```bash
cd ~/labs/lab01
sudo python3 lab_topo.py --controller none
```

```
mininet> net
mininet> h1 ping -c 2 h2
```

**B2. Predict, then check.** Before running the next commands, write down *why* the ping fails.

```
mininet> sh ovs-vsctl get-fail-mode s1
mininet> sh ovs-ofctl -O OpenFlow13 dump-flows s1
mininet> sh ovs-ofctl -O OpenFlow13 show s1
```

Expected:
```
secure
OFPST_FLOW reply (OF1.3) (xid=0x2):          <- empty flow table
```

> **Checkpoint B:** What does `fail-mode secure` mean, and what would `standalone` do instead? Why is `secure` the right choice for an SDN switch?

Exit (`exit`) before Part C.

---

## PART C — Connect Ryu and watch OpenFlow on the wire (core, ~15 min)

Open **three terminals**.

**Terminal 1 — packet capture on the loopback interface** (the controller and switches talk over 127.0.0.1):

*Wireshark GUI:* `wireshark -i lo -k`, display filter **`openflow_v4`**

*or, without a GUI:*
```bash
tshark -i lo -f "tcp port 6653" -w ~/lab1_openflow.pcap
```

**Terminal 2 — the controller:**
```bash
source ~/ryu-venv/bin/activate
ryu-manager --verbose ryu.app.simple_switch_13
```

**Terminal 3 — the network:**
```bash
cd ~/labs/lab01
sudo python3 lab_topo.py               # default: remote controller at 127.0.0.1:6653
```

**C1. The handshake.** As soon as the switches start, look at Wireshark. For each switch you should see:
`HELLO ↔ HELLO → FEATURES_REQUEST → FEATURES_REPLY → (PORT_DESC multipart) → FLOW_MOD (table-miss)`.

Click the **FEATURES_REPLY** and find the `datapath_id` and `n_tables`. Click the first **FLOW_MOD** and find `priority = 0`, an empty match and the action `OUTPUT: CONTROLLER`.

> **Checkpoint C1:** Why does `simple_switch_13` install this "table-miss" flow straight away? (Hint: compare OpenFlow 1.0 and 1.3 behaviour for unmatched packets.)

**C2. One ping, step by step.** Clear the Wireshark view, then:

```
mininet> h1 ping -c 1 h6
```

In Terminal 2, Ryu prints a line per Packet-In:
```
packet in 1 00:00:00:00:00:01 ff:ff:ff:ff:ff:ff 1     <- ARP request from h1, broadcast, on s1
packet in 2 00:00:00:00:00:01 ff:ff:ff:ff:ff:ff 3     <- same ARP, flooded to s2
packet in 3 00:00:00:00:00:01 ff:ff:ff:ff:ff:ff 3     <- ... and to s3
packet in 3 00:00:00:00:00:06 00:00:00:00:00:01 2     <- ARP reply from h6
...
```

In Wireshark, find a **PACKET_IN** → the following **FLOW_MOD** → **PACKET_OUT**. Expand the Packet-In and identify the `in_port`, the `reason` (`NO_MATCH`/table-miss) and the encapsulated Ethernet frame.

**C3. Look at the result in the switches:**

```
mininet> sh ovs-ofctl -O OpenFlow13 dump-flows s2
```
Expected (abridged):
```
 priority=1,in_port=1,dl_src=00:00:00:00:00:03,dl_dst=00:00:00:00:00:01 actions=output:3
 priority=1,in_port=3,dl_src=00:00:00:00:00:01,dl_dst=00:00:00:00:00:03 actions=output:1
 ...
 priority=0 actions=CONTROLLER:65535
```

**C4. Now the whole network:**
```
mininet> pingall
*** Results: 0% dropped (30/30 received)
```

Stop the capture. If you used tshark, summarise the message types:

```bash
tshark -r ~/lab1_openflow.pcap -Y openflow_v4 -T fields -e openflow_v4.type | sort -n | uniq -c
```

Example from a reference run (pingall + one ping):
```
      7 0      HELLO
      3 5      FEATURES_REQUEST       (one per switch)
      3 6      FEATURES_REPLY
    107 10     PACKET_IN
     21 12     PORT_STATUS
    107 13     PACKET_OUT
     65 14     FLOW_MOD
      3 18     MULTIPART_REQUEST      (port description)
      3 19     MULTIPART_REPLY
```

> **Checkpoint C (core check-off):** show the instructor (1) `pingall` at 0% dropped, (2) a Wireshark/tshark view with a PACKET_IN → FLOW_MOD pair, (3) the flow table of `s2`. Explain why there are as many PACKET_OUTs as PACKET_INs, but fewer FLOW_MODs.

---

## PART D — Write your own controller apps (extended, ~45 min)

### D1. The hub: the controller does everything

Read `hub_13.py`. It has only two handlers:
- `switch_features_handler` installs the table-miss entry;
- `packet_in_handler` floods **every** packet and never installs a forwarding flow.

Run it (stop the previous Ryu first, `Ctrl-C`):

```bash
ryu-manager --verbose hub_13.py        # Terminal 2
sudo python3 lab_topo.py               # Terminal 3
mininet> pingall
mininet> iperf h1 h6
mininet> sh ovs-ofctl -O OpenFlow13 dump-flows s1
```

You'll see a single flow whose `n_packets` keeps growing: every packet visits the controller.

### D2. The learning switch: the controller teaches the switch

Read `learning_switch_13.py`. The Packet-In handler has four steps. Find each one in the code:

```
1 LEARN    mac_to_port[dpid][src] = in_port
2 DECIDE   out_port = mac_to_port[dpid].get(dst, FLOOD)
3 INSTALL  if dst is known -> FLOW_MOD (match in_port,src,dst ; action output) with idle_timeout
4 FORWARD  PACKET_OUT for the packet that triggered this event
```

Compared with `simple_switch_13`, this version adds `idle_timeout=20` and asks the switch to report expired flows (`OFPFF_SEND_FLOW_REM`).

```bash
ryu-manager --verbose learning_switch_13.py
sudo python3 lab_topo.py
mininet> h1 ping -c 3 h3
# now wait ~20 s without traffic and watch Terminal 2
```

Expected in the Ryu log:
```
FLOW_REMOVED dpid=2 match={'in_port': 1, 'eth_src': '00:00:00:00:00:03', 'eth_dst': '00:00:00:00:00:01'} packets=3 duration=25s reason=0
```
(`reason=0` = `OFPRR_IDLE_TIMEOUT`.)

### D3. Measure it

Fill in this table, with **3 runs each**, as mean ± std:

| Metric | Hub | Learning switch |
|---|---|---|
| RTT of the **1st** ping h1→h6 (ms) | | |
| Average RTT of pings 2–10 (ms) | | |
| `iperf h1 h6` throughput (Mbit/s) | | |
| Packet-Ins during the iperf run (count lines in the Ryu log) | | |
| Flows in s2 after `pingall` | | |

Useful commands:
```bash
mininet> h1 ping -c 10 h6                      # first line = first-packet RTT
ryu-manager hub_13.py 2>&1 | tee hub.log       # then: grep -c "dpid=" hub.log
```

> **Analysis D:**
> 1. Why is the first ping slower than the rest with the learning switch? Break the extra delay into its components (ARP, Packet-In, controller processing, Flow-Mod).
> 2. Why does the hub's throughput collapse? Which resource is the bottleneck?
> 3. Ryu matches on `(in_port, eth_src, eth_dst)`. How many flows does a fully meshed `pingall` create on `s2`? Derive the formula for *N* hosts and compare it to your measurement. What does this mean for TCAM size in a real switch?

### D4. Programming exercise (graded)

Modify `learning_switch_13.py` to **block all traffic between h1 and h4** in both directions:
- install the block as **proactive** flows in `switch_features_handler` (priority higher than the learned flows, empty instruction list = drop);
- `h1 ping h4` must fail, while every other pair still works (`pingall` shows exactly 2 failures);
- bonus: make the blocked pairs a list at the top of the file.

*Hint:* `parser.OFPMatch(eth_src="00:00:00:00:00:01", eth_dst="00:00:00:00:00:04")`, and `self.add_flow(dp, 100, match, [])`.

---

## PART E — Emulating long links (extended, ~20 min) — a first look at NTN

`lab_topo.py` can shape the two **core links** (s1–s2 and s2–s3):

```bash
ryu-manager ryu.app.simple_switch_13
sudo python3 lab_topo.py --delay 60ms --bw 20
```

**E1. Predict, then measure.** Mininet applies `delay` on *both* ends of a link, so each direction of each link adds 60 ms.

| Path | Links crossed | Predicted RTT | Measured RTT (ping -c 10, avg) |
|---|---|---|---|
| h1 → h2 | 0 | | |
| h1 → h3 | 1 | | |
| h1 → h6 | 2 | | |

**E2. TCP over a "satellite" link.** Compare `iperf h1 h6` for `--delay 2ms`, `--delay 30ms` (≈ LEO) and `--delay 135ms` (≈ GEO, so the 2-link RTT ≈ 540 ms, the 3GPP GEO figure), then add `--loss 1`.

> **Analysis E:** Plot throughput against RTT. Explain the result using the bandwidth–delay product and the Mathis et al. approximation  *throughput ≈ (MSS/RTT)·(1.22/√p)*. Why do satellite operators deploy **Performance-Enhancing Proxies (PEPs)**, and how could an SDN/NFV architecture place them?

---

## PART F — Break it: loops (extended, ~15 min)

`--loop` adds a link s1–s3 (port 4 on both), creating a physical loop ([*Lab 1 - loop variant*](topology.md#lab-1---loop-variant)).

> ⚠️ This will spike CPU usage. Run it for **5 seconds**, then stop Ryu with `Ctrl-C`.

```bash
ryu-manager ryu.app.simple_switch_13 2>&1 | tee loop.log
sudo python3 lab_topo.py --loop
mininet> h1 ping -c 3 h6
```

Reference observation: **100% packet loss**, and about **15,000 Packet-In log lines in under 10 seconds**: a broadcast storm. Each flooded ARP comes back on another port, so the controller keeps "learning" h1's MAC on the wrong port.

**Now fix it** with Ryu's spanning-tree version of the switch:

```bash
sudo mn -c
ryu-manager ryu.app.simple_switch_stp_13
sudo python3 lab_topo.py --loop
# wait ~30-45 s for STP to converge, watching the [STP] log lines
mininet> h1 ping -c 3 h6
```

Reference result: one port is put in `BLOCK` state (in our run, `dpid=3 port=3 NON_DESIGNATED_PORT / BLOCK`) and ping works at 0% loss.

> **Analysis F:** STP *disables* the redundant link. Why is that wasteful? Explain how an SDN controller with a global topology view (via LLDP discovery, Lab 5) can avoid loops **and** still use every link (e.g. per-flow shortest paths, ECMP with `select` groups). Why does this matter even more in an LEO mesh with inter-satellite links?

---

## 3. Research extension (choose one, ~1 page in the report)

1. **Controller placement and control-channel latency.** Add latency to the control channel only: `sudo tc qdisc add dev lo root netem delay 20ms` (remove with `sudo tc qdisc del dev lo root`). Measure first-packet RTT for 0, 20, 120 and 270 ms (a GEO-hosted controller!). Plot it and discuss what it means for placing SDN controllers in an NTN (ground station vs GEO vs LEO), with reference to Heller et al., *The Controller Placement Problem* (HotSDN 2012).
2. **Control-plane load.** Using `sudo mn --topo tree,depth=3,fanout=3 --mac --switch ovsk,protocols=OpenFlow13 --controller remote,port=6653`, measure Packet-In count and controller CPU during `pingall` as the network grows. Where does reactive control stop scaling?
3. **Proactive vs reactive.** Design an experiment comparing first-packet latency and flow-table size for reactive learning versus proactively installed rules (preview of Lab 2). State the hypothesis first.

---

## 4. Lab report checklist (Lab 1)

- [ ] `check_env.sh` output and software versions
- [ ] Topology diagram (your own drawing) and the `net` output
- [ ] Checkpoint answers A, B, C1, C
- [ ] Annotated Wireshark screenshot of handshake + PACKET_IN → FLOW_MOD → PACKET_OUT, plus the message-type count table
- [ ] Table D3 with mean ± std, and Analysis D
- [ ] D4 code (diff against the original) and `pingall` output proving it works
- [ ] Part E table, plot and analysis
- [ ] Part F observations and analysis
- [ ] Research extension

---

## 5. Troubleshooting

| Problem | Fix |
|---|---|
| Switches never connect (Ryu prints nothing) | Is Ryu running *before* Mininet? `sudo ovs-vsctl show` should list `Controller "tcp:127.0.0.1:6653"` with `is_connected: true` |
| `pingall` 100% dropped with Ryu running | Wrong OpenFlow version: switches must use `protocols=OpenFlow13` (`lab_topo.py` does this) |
| Wireshark shows TCP but not OpenFlow | Use the display filter `openflow_v4`; if your controller listens on 6633, *Decode As → OpenFlow* |
| `RTNETLINK answers: File exists` | `sudo mn -c` |
| Everything slow after Part F | Ryu is still storming. `Ctrl-C` it, then `sudo mn -c` |
| WSL2 / no OVS kernel module | `sudo python3 lab_topo.py --datapath user` |

---