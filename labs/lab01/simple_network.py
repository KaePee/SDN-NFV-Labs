#!/usr/bin/env python3

from mininet.net import Mininet
from mininet.node import RemoteController, OVSKernelSwitch
from mininet.cli import CLI
from mininet.log import setLogLevel, info

def create_sdn_network():
    # 1. Initialize the Mininet object with an Open vSwitch forced to OpenFlow 1.3
    net = Mininet(
        controller=RemoteController, 
        switch=OVSKernelSwitch, 
        build=False
    )

    info('*** Adding Remote Ryu Controller\n')
    # Connect to your Ryu controller running locally on port 6653
    c0 = net.addController('c0', controller=RemoteController, ip='127.0.0.1', port=6653)

    info('*** Adding Open vSwitch\n')
    # Define the switch and explicitly set it to use the OpenFlow 1.3 protocol
    s1 = net.addSwitch('s1', cls=OVSKernelSwitch, protocols='OpenFlow13')

    info('*** Adding 3 Hosts\n')
    # Create 3 separate hosts with dedicated IP addresses
    h1 = net.addHost('h1', ip='10.0.0.1/24')
    h2 = net.addHost('h2', ip='10.0.0.2/24')
    h3 = net.addHost('h3', ip='10.0.0.3/24')

    info('*** Creating Network Links\n')
    # Wire the hosts directly to the switch
    net.addLink(h1, s1)
    net.addLink(h2, s1)
    net.addLink(h3, s1)

    info('*** Starting Network\n')
    # Build the topology and start the components
    net.build()
    c0.start()
    s1.start([c0])

    info('*** Running Mininet Interactive CLI\n')
    # Drop the user into the standard mininet> prompt
    CLI(net)

    info('*** Stopping Network and Cleaning Up\n')
    net.stop()

if __name__ == '__main__':
    # Set log level to info so we can see what Mininet is doing behind the scenes
    setLogLevel('info')
    create_sdn_network()

