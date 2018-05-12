#!/bin/bash

set -e

cd "$(dirname ${BASH_SOURCE[0]})"
ORIGDIR="$PWD"
NETWORK='systemd-networkd'
devices="$ORIGDIR/devices.csv"
end_hosts="$ORIGDIR/end-hosts.csv"
ext_if="$(ip link | grep -v '^[[:space:]]' | awk -F ':' '{print $2}' | \
	tr -d ' \t' | grep '^e' | head -n1)"
depends=('gns3-gui' 'iptables-persistent' 'tigervnc-viewer')

[ $UID -ne 0 ] && (echo 'Abort. please run this script as root' ; exit 1)
[ -r $devices ] || (echo "Error. missing file '$devices'" ; exit 1)
[ -r $end_hosts ] || (echo "Error. missing file '$end_hosts'" ; exit 1)


make_external()
{
	cat <<EOF > 00-external.network
[Match]
Name=$ext_if

[Network]
DHCP=ipv4
EOF
}

make_tap()
{
	iface=$1
	addr=$2
	peer_addr=$(echo $3 | awk -F '/' '{print $1}')
	cat <<EOF > 00-$iface.netdev
[Match]

[NetDev]
Name=$iface
Kind=tap
EOF
	cat <<EOF > 01-$iface.network
[Match]
Name=$iface

[Address]
Address=$addr

[Route]
Gateway=$peer_addr
Destination=$peer_addr
EOF
}

make_veth()
{
	iface=$1
	addr=$2
	peer=$(echo $1 | sed 's/veth-//')
	peer_addr=$(echo $3 | awk -F '/' '{print $1}')
	cat <<EOF > 00-$iface.netdev
[Match]

[NetDev]
Name=$iface
Kind=veth

[Peer]
Name=$peer
EOF
	cat <<EOF > 01-$iface.network
[Match]
Name=$iface

[Address]
Address=$addr

[Route]
Gateway=$peer_addr
Destination=$peer_addr
EOF
}

make_bridge_network()
{
	cat <<EOF > 01-host-bridges.network
[Match]
Name=br-host-*

[Bridge]
AllowPortToBeRoot=off
EOF
}

make_bridge()
{
	iface="br-$1"
	cat <<EOF > 00-$iface.netdev
[Match]

[NetDev]
Name=$iface
Kind=bridge

[Bridge]
STP=on
EOF
}

make_tap_host()
{
	iface="tap-$1"
	bridge="br-$1"
	cat <<EOF > 00-$iface.netdev
[Match]

[NetDev]
Name=$iface
Kind=tap
EOF
	cat <<EOF > 01-$iface.network
[Match]
Name=$iface

[Network]
Bridge=$bridge
EOF
}

make_veth_eh()
{
	iface="$(echo $1 | sed 's/host/veth-eh/')"
	peer="$(echo $1 | sed 's/host/eth/')"
	bridge="br-$1"
	cat <<EOF > 00-$iface.netdev
[Match]

[NetDev]
Name=$iface
Kind=veth

[Peer]
Name=$peer
EOF
	cat <<EOF > 01-$iface.network
[Match]
Name=$iface

[Network]
Bridge=$bridge
EOF
}

make_end_hosts_sh()
{
	cat <<EOF > end-hosts.sh
#!/bin/bash

set -e

[ \$UID -ne 0 ] && (echo 'Abort. please run this script as root' ; exit 1)

EOF
	# create network namespaces
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk '{print "ip netns add ns-" $1}' >> end-hosts.sh
	echo >> end-hosts.sh

	# put interfaces in the network namespaces
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk '{print "ip link set " $1 " netns ns-" $1}' >> end-hosts.sh
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk '{print "ip link set " $1 " netns ns-" $1}' | \
		sed 's/ host/ eth/' >> end-hosts.sh
	echo >> end-hosts.sh

	# configure interfaces in the network namespaces
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk '{print "ip netns exec ns-" $1 " ip link set " $1 " up"}' \
		>> end-hosts.sh
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk '{print "ip netns exec ns-" $1 " ip addr add " $2 " dev " $1}' \
		>> end-hosts.sh
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk '{print "ip netns exec ns-" $1 " ip link set " $1 " up"}' | \
		sed 's/ host/ eth/' >> end-hosts.sh
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk '{print "ip netns exec ns-" $1 " ip addr add " $3 " dev " $1}' | \
		sed 's/ host/ eth/' >> end-hosts.sh

	# configure default gateways for the interfaces
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk '{
	print "ip netns exec ns-" $1 " ip route add default via " $4 " dev " $1 " metric 100";
	print "ip netns exec ns-" $1 " ip route add default via " $5 " dev " $1 " metric 200";
		}' | \
		sed 's/ host/ eth/' >> end-hosts.sh
	echo >> end-hosts.sh

	# spawn ssh daemons in all the network namespaces
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | \
		awk "{print \"ip netns exec ns-\" \$1 \" $(which sshd)\"}" \
		>> end-hosts.sh
}

make_end_hosts_service()
{
	cat <<EOF > end-hosts.service
[Unit]
Description = Service creating all end hosts for GNS3 network
Wants       = network.target
Before      = network.target multi-user.target
Requires    = systemd-networkd.service
After       = systemd-networkd.service

[Service]
Type = forking
Restart = no
ExecStart = /usr/local/bin/end-hosts.sh
RuntimeDirectory=sshd
RuntimeDirectoryMode=0755

[Install]
WantedBy = multi-user.target
EOF
}

setup_ssh_path()
{
	pushd $NETWORK
	make_external
	cat $devices | sed '/^[[:space:]]*#.*$/d' | awk '{print $3 " " $4 " " $2}' | \
	while read line; do
		if echo $line | grep '^tap' &>/dev/null; then
			make_tap $line
		elif echo $line | grep '^veth' &>/dev/null; then
			make_veth $line
		else
			echo "Error. unrecognized interface config: $line"
			exit 1
		fi
	done
	popd
}

setup_end_hosts()
{
	pushd $NETWORK
	make_bridge_network
	cat $end_hosts | sed '/^[[:space:]]*#.*$/d' | awk '{print $1}' | \
	while read line; do
		make_bridge $line
		make_tap_host $line
		make_veth_eh $line
	done
	popd

	make_end_hosts_sh
	make_end_hosts_service
}

setup_etc_hosts()
{
	cat $devices | sed '/^[[:space:]]*#.*$/d' | awk '{print $2 "\t" $1}' | \
		sed 's/\/31//' > hosts
}

setup_iptables()
{
	cat <<EOF > 90-firewall.conf
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.all.rp_filter=1
EOF
	cat <<EOF > iptables.rules
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
EOF
	cat $devices | sed '/^[[:space:]]*#.*$/d' | awk "{
		print \"-A PREROUTING -p tcp -i $ext_if --dport \" \$5 \" -j DNAT --to-destination \" \$2 \":22\"
		}" | sed 's/\/31//' >> iptables.rules
	cat $devices | sed '/^[[:space:]]*#.*$/d' | \
		awk "{print \"-A POSTROUTING -o \" \$3 \" -j MASQUERADE\"}" \
		>> iptables.rules
	cat <<EOF >> iptables.rules
-A POSTROUTING -o $ext_if -j MASQUERADE
COMMIT

*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:SRC - [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -p icmp -j SRC
-A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -m conntrack --ctstate INVALID -j DROP
-A INPUT -p tcp -m conntrack --ctstate NEW -j SRC
-A INPUT -p tcp -j REJECT --reject-with tcp-reset
-A INPUT -p udp -j REJECT --reject-with icmp-port-unreachable
-A INPUT -j REJECT --reject-with icmp-proto-unreachable
-A FORWARD -p icmp -j SRC
-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A FORWARD -p tcp -d 192.168.0.0/24 --dport 22 -m conntrack --ctstate NEW -j SRC
-A FORWARD -j REJECT --reject-with icmp-proto-unreachable
-A SRC -i $ext_if -j ACCEPT
EOF
	cat $devices | sed '/^[[:space:]]*#.*$/d' | \
		awk "{print \"-A SRC -i \" \$3 \" -s \" \$2 \" -j ACCEPT\"}" \
		>> iptables.rules
	echo 'COMMIT' >> iptables.rules

	if dpkg --list | grep ufw; then
		ufw disable
		apt -y remove --purge ufw
	fi
}

deploy()
{
	install -Dm 644 90-firewall.conf -t /etc/sysctl.d/
	install -Dm 644 end-hosts.service -t /etc/systemd/system/
	install -Dm 755 end-hosts.sh -t /usr/local/bin/
	install -Dm 644 hosts -t /etc/
	install -Dm 644 iptables.rules /etc/iptables/rules.v4
	rm -rf /etc/systemd/network/*
	install -Dm 644 systemd-networkd/* -t /etc/systemd/network/

	systemctl daemon-reload
	systemctl disable networking
	systemctl is-enabled end-hosts.service >/dev/null || systemctl enable end-hosts.service
	systemctl is-enabled systemd-networkd.service >/dev/null || systemctl enable systemd-networkd.service
	netfilter-persistent restart
}


TMPDIR="$(mktemp -d)"
pushd $TMPDIR
mkdir $NETWORK

add-apt-repository -y ppa:gns3/ppa
apt update
apt -y upgrade
apt -y install ${depends[*]}

setup_ssh_path
setup_end_hosts
setup_etc_hosts
setup_iptables

apt -y autoremove
apt -y purge
apt -y autoclean
apt -y clean

deploy

popd
rm -rf $TMPDIR
