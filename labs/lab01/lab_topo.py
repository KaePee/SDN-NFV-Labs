#!/usr/bin/env python3
r"""
TE 578/778 - Lab 1 & Lab 2 topology
Topology: see lab01/topology.md, diagram "Lab 1 - topology"
(and "Lab 1 - loop variant" for --loop).
In words: 3 switches in a line, 2 hosts per switch (6 hosts). Host n has
IP 10.0.0.n and MAC 00:00:00:00:00:0n. Port numbers are fixed on purpose so
that flow rules in the lab handouts are predictable:
  s1: h1->1, h2->2, s2->3          (--loop adds s1:4 <-> s3:4)
  s2: h3->1, h4->2, s1->3, s3->4
  s3: h5->1, h6->2, s2->3

Usage examples
  sudo python3 lab_topo.py                       # remote controller on 127.0.0.1:6653
  sudo python3 lab_topo.py --controller none     # no controller (Lab 2, ovs-ofctl)
  sudo python3 lab_topo.py --delay 20ms --bw 10  # shape the inter-switch links
  sudo python3 lab_topo.py --loop                # add an s1-s3 link (creates a loop!)
  sudo python3 lab_topo.py --loop --static-arp --controller none   # Lab 2 fast-failover

You can also load it with the mn command:
  sudo mn --custom lab_topo.py --topo lab --mac \
          --switch ovsk,protocols=OpenFlow13 --controller remote,port=6653
"""
import argparse
from functools import partial

from mininet.cli import CLI
from mininet.link import TCLink
from mininet.log import info, setLogLevel
from mininet.net import Mininet
from mininet.node import OVSKernelSwitch, RemoteController
from mininet.topo import Topo


class LabTopo(Topo):
    """Linear 3-switch topology with 2 hosts per switch."""

    def build(self, bw=None, delay=None, loss=None, loop=False):
        # Parameters for the inter-switch ("core") links only
        core = {}
        if bw:
            core["bw"] = float(bw)
        if delay:
            core["delay"] = delay
        if loss:
            core["loss"] = float(loss)

        switches = [self.addSwitch(f"s{i}", protocols="OpenFlow13") for i in (1, 2, 3)]

        # Hosts: h1,h2 on s1; h3,h4 on s2; h5,h6 on s3 (host ports 1 and 2)
        n = 1
        for sw in switches:
            for port in (1, 2):
                h = self.addHost(f"h{n}", ip=f"10.0.0.{n}/24", mac=f"00:00:00:00:00:{n:02x}")
                self.addLink(h, sw, port2=port)
                n += 1

        s1, s2, s3 = switches
        self.addLink(s1, s2, port1=3, port2=3, **core)
        self.addLink(s2, s3, port1=4, port2=3, **core)
        if loop:
            # WARNING: creates a forwarding loop (broadcast storm with a naive controller)
            self.addLink(s1, s3, port1=4, port2=4, **core)


# Allows: sudo mn --custom lab_topo.py --topo lab
topos = {"lab": LabTopo}


def main():
    parser = argparse.ArgumentParser(description="TE 578/778 lab topology")
    parser.add_argument("--controller", default="remote", choices=["remote", "none"])
    parser.add_argument("--ip", default="127.0.0.1", help="controller IP")
    parser.add_argument("--port", type=int, default=6653, help="controller port")
    parser.add_argument("--bw", help="core link bandwidth in Mbit/s, e.g. 10")
    parser.add_argument("--delay", help="core link delay, e.g. 20ms")
    parser.add_argument("--loss", help="core link loss in percent, e.g. 1")
    parser.add_argument("--loop", action="store_true", help="add s1-s3 link")
    parser.add_argument("--static-arp", action="store_true",
                        help="pre-fill every host's ARP table (no ARP broadcasts needed)")
    parser.add_argument("--datapath", default="kernel", choices=["kernel", "user"],
                        help="OVS datapath (use 'user' only if the kernel module is missing)")
    args = parser.parse_args()

    topo = LabTopo(bw=args.bw, delay=args.delay, loss=args.loss, loop=args.loop)
    switch = partial(OVSKernelSwitch, datapath=args.datapath)

    net = Mininet(topo=topo, switch=switch, link=TCLink, controller=None,
                  autoSetMacs=False, build=True)
    if args.controller == "remote":
        net.addController("c0", controller=RemoteController, ip=args.ip, port=args.port)

    net.start()
    if args.static_arp:
        net.staticArp()
    if args.datapath == "user":
        # The userspace datapath does not fix up checksums offloaded by veth
        # interfaces: ping works but TCP silently fails. Turn TX offload off.
        for h in net.hosts:
            for intf in h.intfNames():
                h.cmd(f"ethtool -K {intf} tx off >/dev/null 2>&1")
    info("\n*** Topology ready. Try: nodes, net, links, pingall, h1 ping -c3 h6\n\n")
    CLI(net)
    net.stop()


if __name__ == "__main__":
    setLogLevel("info")
    main()
