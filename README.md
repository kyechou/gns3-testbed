GNS3 Testbed
============

The script `setup.sh` can be used to set up a GNS3 testbed on an Ubuntu machine.
You can also download the pre-built virtual machine image built from the script
and the configuration files in this repository.


Using the pre-built OVA image
-----------------------------

Download the OVA image from [this
link](https://drive.google.com/open?id=1b45on6LJ3cIncgQieHtOtbJceNP5xD-o) and
then deploy the image template in VirtualBox or VMware. The image works better
when given more than 8~9 GiB memory. Once you boot up the virtual machine, you
should be able to launch the GNS3 client UI with local server by clicking the
GNS3 icon in the launcher bar.


Configurations
--------------

There are two configuration files read by the setup script.

`devices.csv` specifies connection information of all the devices, including
Cisco switches, ASAv firewalls, and end hosts with network namespaces. You would
have to change this configuration file before running the setup script if you
changed the topology.

`end-hosts.csv` specifies all the end hosts and the IP addresses of all the
interfaces it needs. It reads two default gateways by default, one with metric
100 and the other with metric 200. If the topology is changed and there is only
one default gateway for each end host, you should modify `end-hosts.csv` by
removing the second gateway, and also delete the 195-th line in `setup.sh`.


Setting Up the Environment from Scratch
---------------------------------------

Before executing the script, please make sure the machine has Internet access.
And then run the `setup.sh` with root privilege.

The script will install all the needed packages, set up network interfaces with
the systemd-networkd service, set up network namespaces for simulating end hosts
in the GNS3 network, and update the IPtables rules for redirecting the SSH
connection traffic to corresponding devices or end hosts.

After setting up the host environment with the `setup.sh`. We should now launch
GNS3, create a temporary empty project to import the needed images/appliances:

- [cisco-asav.gns3a](https://drive.google.com/open?id=1Bqfc83Ge8ups5L5XoOkEIe2sJ7zNJWhd)
- [asav981.qcow2](https://drive.google.com/open?id=1fyn1jTqemZ4aTfNtIYy4HeDUUfRvQnp8)
- [c3745-advipservicesk9-mz.124-25d.bin](https://drive.google.com/open?id=1nC8lIDqcZQTba_lufhwm5YjlsHigKn_b)

The ASAv firewall image uses KVM by default. In case you would like to enable
nested KVM virtualization, please refer to _[How to enable nested virtualization
in KVM](https://docs.fedoraproject.org/quick-docs/en-US/using-nested-virtualization-in-kvm.html)_.
Though VMware support nested KVM, the VMware player, workstation, and ESXi,
however, don't seem to support the ASAv image (ASAv 9.8.1) running with KVM. It
is said that the 9.5.2 image `ASAv952-204.qcow2` is known to work well, but it
has been removed by Cisco. As a result, we had to run the firewall images
without KVM by modifying the additional QEMU options to `-nographic -no-kvm
-icount auto -cpu Nehalem` in `Edit` -> `Preference` -> `QEMU VMs` ->
`[template]` -> `Edit` -> `Advanced settings` -> `Additional settings` ->
`Options`.

When the above configurations are done and one can successfully launch a ASAv
firewall instance in the temporary project, it's time to import the portable
project archive. First, download the exported project file from
[testbed.gns3project](https://drive.google.com/open?id=1xdELXBh21zZOC-Wjq_pmZoKlI_E8vuJf).
Then choose the downloaded project to import in `File` -> `Import portable
project`.

Finally, remember to reboot the system in order for the services to create and
configure the interfaces, and the temporary project can be deleted now.


Concerns & TODOs
----------------

### Cisco switch images

We've tried the images of Cisco 3640 and 7200, both of which don't seem to work
well. The 3640 image, `c3640-ik9o3s-mz124-13.bin`, is unable to run SSH service
after rebooting the device in that it cannot restore the SSH key (actually some
instances can, but most can not). SSH works well with the 7200 image,
`c7200-advipservicesk9-mz.152-4.S5.bin`, but it cannot create VLANs since it is
not an Ethernet switch. As a result, we use the Cisco 3745 image, which works
well with both SSH and VLAN.

Another issue for the 3745 image is mentioned in [the
post](http://forum.gns3.net/topic2786.html). The switches cannot ping each other
through the SVIs for VLANs. A solution proposed later by kellerg in the same
thread solved the problem by simply removing the second NM-16ESW module from the
switches.

### Cisco ASAv images

As mentioned in the previous section of setting up the environment, the ASAv
firewall image requires KVM by default, which makes VirtualBox and VMware player
unable to run the ASAv image inside a virtual machine. VirtualBox doesn't
support nested KVM virtualization yet, and even though VMware supports nested
KVM (VT-x), it doesn't work well with the ASAv image we have, ASAv 9.8.1.

In order to run the ASAv firewall image without KVM, we disabled the KVM by
modifying some of QEMU's additional options. However, it makes the QEMU firewall
instances run much slower than those with KVM enabled, and it seems unable to
run multiple firewall instances at the same time.

So, we can either run one instance of the ASAv firewall inside the virtual
machine without KVM, or connect to physical ASA firewalls by bridging the
interface that physically connects to the ASA firewall to the GNS3 network.

### Topology and VLAN bridging

For the original topology design, we tried to bridge between SVIs for different
VLANs so as to have the same layer-2 LAN across devices, but it had issues about
switching loops in the network, because the ASAv firewalls do not support
layer-2 switching and so the firewalls do not support STP and forward the
layer-2 frames to all ports configured with the same VLAN.

After a while, we re-designed the topology so that there are layer-2 switches
between the firewalls and the core routers, and that the links between the
firewalls are supposed to enable the failover between the firewalls and are
currently shut down and not used.

### TODO

A big performance bottle neck is the memory consumed by the firewalls and the
switches. It may take some time to boot up all the devices at once, and, as
mentioned above, it's quite difficult to run more than one firewall instance at
the same time. So for the class, it might be better to:

- Run only one firewall with simplified topology inside the virtual machine (without KVM).
- Run the full topology on physical machine with Linux and KVM.
- Run the switches in GNS3 inside the virtual machine and connect to the physical ASA firewalls.

