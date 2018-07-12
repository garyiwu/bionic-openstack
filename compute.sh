#!/bin/bash -x

if [ "$#" -ne 1 ]; then
    export IP_ADDR=$(hostname -i)
else
    export IP_ADDR=$1
fi

export DEBIAN_FRONTEND=noninteractive

source passwords.sh

apt -y install python3-openstackclient crudini

#
# Nova
#
apt -y install nova-compute
# Need to do this twice for some reason
apt -y install nova-compute

crudini --merge /etc/nova/nova.conf <<EOF
[DEFAULT]
transport_url = rabbit://openstack:$RABBIT_PASS@controller
my_ip = $IP_ADDR
use_neutron = True
firewall_driver = nova.virt.firewall.NoopFirewallDriver

[api]
auth_strategy = keystone

[keystone_authtoken]
auth_url = http://controller:5000/v3
memcached_servers = controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = $NOVA_PASS

[vnc]
enabled = True
server_listen = 0.0.0.0
server_proxyclient_address = \$my_ip
novncproxy_base_url = http://controller:6080/vnc_auto.html

[glance]
api_servers = http://controller:9292

[oslo_concurrency]
lock_path = /var/lib/nova/tmp

[placement]
os_region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://controller:5000/v3
username = placement
password = $PLACEMENT_PASS

[filter_scheduler]
available_filters = nova.scheduler.filters.all_filters
enabled_filters = RetryFilter, AvailabilityZoneFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter, NUMATopologyFilter
EOF
crudini --del /etc/nova/nova.conf DEFAULT log_dir
service nova-compute restart

#
# Neutron
#
apt -y install neutron-linuxbridge-agent

crudini --del /etc/neutron/neutron.conf database connection
crudini --merge /etc/neutron/neutron.conf <<EOF
[DEFAULT]
transport_url = rabbit://openstack:$RABBIT_PASS@controller
auth_strategy = keystone

[keystone_authtoken]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = $NEUTRON_PASS
EOF

export PROVIDER_INTERFACE_NAME=$(ip -o -4 route show to default | awk '{print $5}')
crudini --merge /etc/neutron/plugins/ml2/linuxbridge_agent.ini <<EOF
[linux_bridge]
physical_interface_mappings = provider:$PROVIDER_INTERFACE_NAME

[vxlan]
enable_vxlan = true
local_ip = $IP_ADDR
l2_population = true

[securitygroup]
enable_security_group = true
firewall_driver = neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
EOF

crudini --merge /etc/nova/nova.conf <<EOF
[neutron]
url = http://controller:9696
auth_url = http://controller:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = $NEUTRON_PASS
EOF
service nova-compute restart
service neutron-linuxbridge-agent restart
