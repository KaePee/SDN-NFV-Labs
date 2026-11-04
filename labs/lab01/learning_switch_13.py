# TE 578/778 - Lab 1 (Part D): an annotated L2 learning switch (OpenFlow 1.3).
# Topology: see lab01/topology.md, diagrams "Lab 1 - topology" and "Lab 1 - reactive flow setup".
# Same idea as ryu/app/simple_switch_13.py, plus:
#   * flows expire after IDLE_TIMEOUT seconds of inactivity
#   * the switch reports expired flows (Flow-Removed) and we log them
#
# Run:  ryu-manager --verbose learning_switch_13.py

from ryu.base import app_manager
from ryu.controller import ofp_event
from ryu.controller.handler import CONFIG_DISPATCHER, MAIN_DISPATCHER, set_ev_cls
from ryu.lib.packet import ethernet, ether_types, packet
from ryu.ofproto import ofproto_v1_3

IDLE_TIMEOUT = 20   # seconds; set to 0 to make flows permanent


class LearningSwitch13(app_manager.RyuApp):
    OFP_VERSIONS = [ofproto_v1_3.OFP_VERSION]

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # mac_to_port[dpid][mac] = port  -> the controller's view of the network
        self.mac_to_port = {}

    # ------------------------------------------------------------------ helpers
    def add_flow(self, dp, priority, match, actions, idle=0, buffer_id=None):
        ofp, parser = dp.ofproto, dp.ofproto_parser
        inst = [parser.OFPInstructionActions(ofp.OFPIT_APPLY_ACTIONS, actions)]
        kwargs = dict(datapath=dp, priority=priority, match=match, instructions=inst,
                      idle_timeout=idle, flags=ofp.OFPFF_SEND_FLOW_REM if idle else 0)
        if buffer_id is not None and buffer_id != ofp.OFP_NO_BUFFER:
            kwargs["buffer_id"] = buffer_id
        dp.send_msg(parser.OFPFlowMod(**kwargs))

    # ------------------------------------------------------------------ events
    @set_ev_cls(ofp_event.EventOFPSwitchFeatures, CONFIG_DISPATCHER)
    def switch_features_handler(self, ev):
        dp = ev.msg.datapath
        ofp, parser = dp.ofproto, dp.ofproto_parser
        # Table-miss: unknown traffic goes to the controller
        self.add_flow(dp, 0, parser.OFPMatch(),
                      [parser.OFPActionOutput(ofp.OFPP_CONTROLLER, ofp.OFPCML_NO_BUFFER)])
        self.logger.info("switch %016x connected", dp.id)

    @set_ev_cls(ofp_event.EventOFPPacketIn, MAIN_DISPATCHER)
    def packet_in_handler(self, ev):
        msg = ev.msg
        dp = msg.datapath
        ofp, parser = dp.ofproto, dp.ofproto_parser
        in_port = msg.match["in_port"]

        eth = packet.Packet(msg.data).get_protocols(ethernet.ethernet)[0]
        if eth.ethertype == ether_types.ETH_TYPE_LLDP:
            return  # ignore link-discovery frames
        src, dst = eth.src, eth.dst

        # 1) LEARN: the source MAC lives behind in_port
        self.mac_to_port.setdefault(dp.id, {})[src] = in_port

        # 2) DECIDE: known destination -> that port, otherwise flood
        out_port = self.mac_to_port[dp.id].get(dst, ofp.OFPP_FLOOD)
        actions = [parser.OFPActionOutput(out_port)]
        self.logger.info("PACKET_IN dpid=%s %s -> %s in_port=%s out=%s",
                         dp.id, src, dst, in_port,
                         "FLOOD" if out_port == ofp.OFPP_FLOOD else out_port)

        # 3) INSTALL: if we know where dst is, push a flow so the switch
        #    handles the rest of this conversation without asking us
        if out_port != ofp.OFPP_FLOOD:
            match = parser.OFPMatch(in_port=in_port, eth_src=src, eth_dst=dst)
            self.add_flow(dp, 1, match, actions, idle=IDLE_TIMEOUT, buffer_id=msg.buffer_id)
            if msg.buffer_id != ofp.OFP_NO_BUFFER:
                return  # switch will apply the new flow to the buffered packet

        # 4) FORWARD the packet that triggered this Packet-In
        data = msg.data if msg.buffer_id == ofp.OFP_NO_BUFFER else None
        dp.send_msg(parser.OFPPacketOut(datapath=dp, buffer_id=msg.buffer_id,
                                        in_port=in_port, actions=actions, data=data))

    @set_ev_cls(ofp_event.EventOFPFlowRemoved, MAIN_DISPATCHER)
    def flow_removed_handler(self, ev):
        m = ev.msg
        self.logger.info("FLOW_REMOVED dpid=%s match=%s packets=%d duration=%ds reason=%d",
                         m.datapath.id, dict(m.match.items()), m.packet_count,
                         m.duration_sec, m.reason)
