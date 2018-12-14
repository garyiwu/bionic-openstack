#!/bin/bash -x

# export PROVIDER_INTERFACE_NAME=$(ip -o -4 route show to default | awk '{print $5}')
# the provider interface is the 2nd interface that doesn't have an IP yet
export PROVIDER_INTERFACE_NAME=eno2


if [ "$#" -ne 1 ]; then
    export IP_ADDR=$(hostname -I | tr -d '[:space:]')
else
    export IP_ADDR=$1
fi

export DEBIAN_FRONTEND=noninteractive

source passwords.sh


apt install software-properties-common
add-apt-repository -y cloud-archive:rocky
apt update
apt -y dist-upgrade


apt -y install python-openstackclient crudini

#
# MariaDB
#
apt -y install mariadb-server python-pymysql

cat > /etc/mysql/mariadb.conf.d/99-openstack.cnf <<EOF
[mysqld]
bind-address = $IP_ADDR

default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF

service mysql restart
sleep 10s

mysql -fu root <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

#
# RabbitMQ
#
apt -y install rabbitmq-server
sleep 10s
rabbitmqctl add_user openstack $RABBIT_PASS
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

#
# Memcached
#
apt -y install memcached python-memcache
sed -i "s/127\.0\.0\.1/$IP_ADDR/g" /etc/memcached.conf
service memcached restart
sleep 10s

#
# etcd
#
apt -y install etcd

cat >> /etc/default/etcd <<EOF
ETCD_NAME="controller"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_INITIAL_CLUSTER_STATE="new"
ETCD_INITIAL_CLUSTER_TOKEN="etcd-cluster-01"
ETCD_INITIAL_CLUSTER="controller=http://$IP_ADDR:2380"
ETCD_INITIAL_ADVERTISE_PEER_URLS="http://$IP_ADDR:2380"
ETCD_ADVERTISE_CLIENT_URLS="http://$IP_ADDR:2379"
ETCD_LISTEN_PEER_URLS="http://0.0.0.0:2380"
ETCD_LISTEN_CLIENT_URLS="http://$IP_ADDR:2379"
EOF

systemctl enable etcd
systemctl start etcd
sleep 10s

#
# Keystone
#
mysql -fu root <<EOF
CREATE DATABASE keystone;
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'localhost' IDENTIFIED BY '$KEYSTONE_DBPASS';
GRANT ALL PRIVILEGES ON keystone.* TO 'keystone'@'%' IDENTIFIED BY '$KEYSTONE_DBPASS';
EOF
apt -y install keystone  apache2 libapache2-mod-wsgi
crudini --set /etc/keystone/keystone.conf database connection "mysql+pymysql://keystone:$KEYSTONE_DBPASS@controller/keystone"
crudini --set /etc/keystone/keystone.conf token provider fernet
su -s /bin/sh -c "keystone-manage db_sync" keystone
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
keystone-manage bootstrap --bootstrap-password $ADMIN_PASS \
  --bootstrap-admin-url http://$IP_ADDR:5000/v3/ \
  --bootstrap-internal-url http://$IP_ADDR:5000/v3/ \
  --bootstrap-public-url http://$IP_ADDR:5000/v3/ \
  --bootstrap-region-id RegionOne
sed -i '/#ServerRoot/a ServerName controller' /etc/apache2/apache2.conf
service apache2 restart
sleep 10s


cat > ~/admin-openrc <<EOF
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

cat > ~/demo-openrc <<EOF
export OS_PROJECT_DOMAIN_NAME=Default
export OS_USER_DOMAIN_NAME=Default
export OS_PROJECT_NAME=demo
export OS_USERNAME=demo
export OS_PASSWORD=$DEMO_PASS
export OS_AUTH_URL=http://controller:5000/v3
export OS_IDENTITY_API_VERSION=3
export OS_IMAGE_API_VERSION=2
EOF

source ~/admin-openrc
openstack domain create --description "An Example Domain" example
openstack project create --domain default --description "Service Project" service
openstack project create --domain default --description "Demo Project" demo
openstack user create --domain default --password $DEMO_PASS demo
openstack role create user
openstack role add --project demo --user demo user
openstack token issue

#
# Glance
#
mysql -fu root <<EOF
CREATE DATABASE glance;
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'localhost' IDENTIFIED BY '$GLANCE_DBPASS';
GRANT ALL PRIVILEGES ON glance.* TO 'glance'@'%' IDENTIFIED BY '$GLANCE_DBPASS';
EOF
openstack user create --domain default --password $GLANCE_PASS glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image" image
openstack endpoint create --region RegionOne image public http://$IP_ADDR:9292
openstack endpoint create --region RegionOne image internal http://$IP_ADDR:9292
openstack endpoint create --region RegionOne image admin http://$IP_ADDR:9292
apt -y install glance
crudini --merge /etc/glance/glance-api.conf <<EOF
[database]
connection = mysql+pymysql://glance:$GLANCE_DBPASS@controller/glance

[keystone_authtoken]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = glance
password = $GLANCE_PASS

[paste_deploy]
flavor = keystone

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/
EOF

crudini --merge /etc/glance/glance-registry.conf <<EOF
[database]
connection = mysql+pymysql://glance:$GLANCE_DBPASS@controller/glance

[keystone_authtoken]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = Default
user_domain_name = Default
project_name = service
username = glance
password = $GLANCE_PASS

[paste_deploy]
flavor = keystone
EOF

su -s /bin/sh -c "glance-manage db_sync" glance
service glance-registry restart
service glance-api restart
sleep 10s


#
# Nova
#
mysql -fu root <<EOF
CREATE DATABASE nova_api;
CREATE DATABASE nova;
CREATE DATABASE nova_cell0;
CREATE DATABASE placement;
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'localhost' IDENTIFIED BY '$NOVA_DBPASS';
GRANT ALL PRIVILEGES ON nova_api.* TO 'nova'@'%' IDENTIFIED BY '$NOVA_DBPASS';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'localhost' IDENTIFIED BY '$NOVA_DBPASS';
GRANT ALL PRIVILEGES ON nova.* TO 'nova'@'%' IDENTIFIED BY '$NOVA_DBPASS';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'localhost' IDENTIFIED BY '$NOVA_DBPASS';
GRANT ALL PRIVILEGES ON nova_cell0.* TO 'nova'@'%' IDENTIFIED BY '$NOVA_DBPASS';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'localhost' IDENTIFIED BY '$PLACEMENT_DBPASS';
GRANT ALL PRIVILEGES ON placement.* TO 'placement'@'%' IDENTIFIED BY '$PLACEMENT_DBPASS';
EOF

source ~/admin-openrc
openstack user create --domain default --password $NOVA_PASS nova
openstack role add --project service --user nova admin
openstack service create --name nova --description "OpenStack Compute" compute
openstack endpoint create --region RegionOne compute public http://$IP_ADDR:8774/v2.1
openstack endpoint create --region RegionOne compute internal http://$IP_ADDR:8774/v2.1
openstack endpoint create --region RegionOne compute admin http://$IP_ADDR:8774/v2.1
openstack user create --domain default --password $PLACEMENT_PASS placement
openstack role add --project service --user placement admin
openstack service create --name placement --description "Placement API" placement
openstack endpoint create --region RegionOne placement public http://$IP_ADDR:8778
openstack endpoint create --region RegionOne placement internal http://$IP_ADDR:8778
openstack endpoint create --region RegionOne placement admin http://$IP_ADDR:8778
apt -y install nova-api nova-conductor nova-consoleauth nova-novncproxy nova-scheduler nova-placement-api

crudini --merge /etc/nova/nova.conf <<EOF
[api_database]
connection = mysql+pymysql://nova:$NOVA_DBPASS@controller/nova_api

[database]
connection = mysql+pymysql://nova:$NOVA_DBPASS@controller/nova

[placement_database]
connection = mysql+pymysql://placement:$PLACEMENT_DBPASS@controller/placement

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
enabled = true
server_listen = \$my_ip
server_proxyclient_address = \$my_ip

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

[scheduler]
driver = filter_scheduler
discover_hosts_in_cells_interval = 300

[filter_scheduler]
available_filters = nova.scheduler.filters.all_filters
enabled_filters = RetryFilter, AvailabilityZoneFilter, ComputeFilter, ComputeCapabilitiesFilter, ImagePropertiesFilter, ServerGroupAntiAffinityFilter, ServerGroupAffinityFilter, NUMATopologyFilter, AggregateInstanceExtraSpecsFilter
EOF
crudini --del /etc/nova/nova.conf DEFAULT log_dir
su -s /bin/sh -c "nova-manage api_db sync" nova
su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova
su -s /bin/sh -c "nova-manage db sync" nova
su -s /bin/sh -c "nova-manage cell_v2 list_cells" nova
service nova-api restart
#service nova-consoleauth restart
service nova-scheduler restart
service nova-conductor restart
service nova-novncproxy restart
sleep 10s

source ~/admin-openrc
#openstack compute service list --service nova-compute
openstack compute service list
openstack catalog list
openstack image list
nova-status upgrade check

#
# Neutron
#
mysql -fu root <<EOF
CREATE DATABASE neutron;
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'localhost' IDENTIFIED BY '$NEUTRON_DBPASS';
GRANT ALL PRIVILEGES ON neutron.* TO 'neutron'@'%' IDENTIFIED BY '$NEUTRON_DBPASS';
EOF
source ~/admin-openrc
openstack user create --domain default --password $NEUTRON_PASS neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public http://$IP_ADDR:9696
openstack endpoint create --region RegionOne network internal http://$IP_ADDR:9696
openstack endpoint create --region RegionOne network admin http://$IP_ADDR:9696
apt -y install neutron-server neutron-plugin-ml2 \
  neutron-linuxbridge-agent neutron-l3-agent neutron-dhcp-agent \
  neutron-metadata-agent

crudini --merge /etc/neutron/neutron.conf <<EOF
[database]
connection = mysql+pymysql://neutron:$NEUTRON_DBPASS@controller/neutron

[DEFAULT]
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = true
transport_url = rabbit://openstack:$RABBIT_PASS@controller
auth_strategy = keystone
notify_nova_on_port_status_changes = true
notify_nova_on_port_data_changes = true

[keystone_authtoken]
www_authenticate_uri = http://controller:5000
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = $NEUTRON_PASS

[nova]
auth_url = http://controller:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = nova
password = $NOVA_PASS

[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
EOF

crudini --merge /etc/neutron/plugins/ml2/ml2_conf.ini <<EOF
[ml2]
type_drivers = flat,vlan,vxlan
tenant_network_types = vxlan
mechanism_drivers = linuxbridge,l2population
extension_drivers = port_security

[ml2_type_flat]
flat_networks = provider

[ml2_type_vxlan]
vni_ranges = 1:1000

[securitygroup]
enable_ipset = true
EOF

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

crudini --merge /etc/neutron/l3_agent.ini <<EOF
[DEFAULT]
interface_driver = linuxbridge
EOF

crudini --merge /etc/neutron/dhcp_agent.ini <<EOF
[DEFAULT]
interface_driver = linuxbridge
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
enable_isolated_metadata = true
EOF

crudini --merge /etc/neutron/metadata_agent.ini <<EOF
[DEFAULT]
nova_metadata_host = controller
metadata_proxy_shared_secret = $METADATA_SECRET
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
service_metadata_proxy = true
metadata_proxy_shared_secret = $METADATA_SECRET
EOF

su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf \
  --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
service nova-api restart
service neutron-server restart
service neutron-linuxbridge-agent restart
service neutron-dhcp-agent restart
service neutron-metadata-agent restart
service neutron-l3-agent restart
sleep 10s

source ~/admin-openrc
openstack extension list --network
openstack network agent list

#
# Horizon
#
apt -y install openstack-dashboard
sed -i 's/127\.0\.0\.1/controller/g' /etc/openstack-dashboard/local_settings.py
sed -i 's/^[# ]*OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT.*/OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True/g' /etc/openstack-dashboard/local_settings.py
sed -i 's/^[# ]*OPENSTACK_KEYSTONE_DEFAULT_DOMAIN.*/OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = "Default"/g' /etc/openstack-dashboard/local_settings.py
sed -i 's/^[# ]*OPENSTACK_KEYSTONE_DEFAULT_ROLE.*/OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"/g' /etc/openstack-dashboard/local_settings.py
service apache2 reload

#
# Cinder
#
mysql -fu root <<EOF
CREATE DATABASE cinder;
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'localhost' IDENTIFIED BY '$CINDER_DBPASS';
GRANT ALL PRIVILEGES ON cinder.* TO 'cinder'@'%' IDENTIFIED BY '$CINDER_DBPASS';
EOF

source ~/admin-openrc
openstack user create --domain default --password $CINDER_PASS cinder
openstack role add --project service --user cinder admin
openstack service create --name cinder --description "OpenStack Block Storage" volume
openstack service create --name cinderv2 --description "OpenStack Block Storage" volumev2
openstack service create --name cinderv3 --description "OpenStack Block Storage" volumev3
openstack endpoint create --region RegionOne volume public http://$IP_ADDR:8776/v1/%\(project_id\)s
openstack endpoint create --region RegionOne volume internal http://$IP_ADDR:8776/v1/%\(project_id\)s
openstack endpoint create --region RegionOne volume admin http://$IP_ADDR:8776/v1/%\(project_id\)s
openstack endpoint create --region RegionOne volumev2 public http://$IP_ADDR:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne volumev2 internal http://$IP_ADDR:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne volumev2 admin http://$IP_ADDR:8776/v2/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 public http://$IP_ADDR:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 internal http://$IP_ADDR:8776/v3/%\(project_id\)s
openstack endpoint create --region RegionOne volumev3 admin http://$IP_ADDR:8776/v3/%\(project_id\)s
apt -y install cinder-api cinder-scheduler

crudini --merge /etc/cinder/cinder.conf <<EOF
[database]
connection = mysql+pymysql://cinder:$CINDER_DBPASS@controller/cinder

[DEFAULT]
transport_url = rabbit://openstack:$RABBIT_PASS@controller
auth_strategy = keystone
my_ip = $IP_ADDR

[keystone_authtoken]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_id = default
user_domain_id = default
project_name = service
username = cinder
password = $CINDER_PASS

[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
EOF
su -s /bin/sh -c "cinder-manage db sync" cinder

crudini --merge /etc/nova/nova.conf <<EOF
[cinder]
os_region_name = RegionOne
EOF
service nova-api restart
service cinder-scheduler restart
service apache2 restart
openstack volume service list
sleep 10s

#
# Heat
#
mysql -fu root <<EOF
CREATE DATABASE heat;
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'localhost' IDENTIFIED BY '$HEAT_DBPASS';
GRANT ALL PRIVILEGES ON heat.* TO 'heat'@'%' IDENTIFIED BY '$HEAT_DBPASS';
EOF

source ~/admin-openrc
openstack user create --domain default --password $HEAT_PASS heat
openstack role add --project service --user heat admin
openstack service create --name heat --description "Orchestration" orchestration
openstack service create --name heat-cfn --description "Orchestration" cloudformation
openstack endpoint create --region RegionOne orchestration public http://$IP_ADDR:8004/v1/%\(tenant_id\)s
openstack endpoint create --region RegionOne orchestration internal http://$IP_ADDR:8004/v1/%\(tenant_id\)s
openstack endpoint create --region RegionOne orchestration admin http://$IP_ADDR:8004/v1/%\(tenant_id\)s
openstack endpoint create --region RegionOne cloudformation public http://$IP_ADDR:8000/v1
openstack endpoint create --region RegionOne cloudformation internal http://$IP_ADDR:8000/v1
openstack endpoint create --region RegionOne cloudformation admin http://$IP_ADDR:8000/v1
openstack domain create --description "Stack projects and users" heat
openstack user create --domain heat --password $HEAT_DOMAIN_PASS heat_domain_admin
openstack role add --domain heat --user-domain heat --user heat_domain_admin admin
openstack role create heat_stack_owner
openstack role add --project demo --user demo heat_stack_owner
openstack role create heat_stack_user
apt-get -y install heat-api heat-api-cfn heat-engine

crudini --merge /etc/heat/heat.conf <<EOF
[database]
connection = mysql+pymysql://heat:$HEAT_DBPASS@controller/heat

[DEFAULT]
transport_url = rabbit://openstack:$RABBIT_PASS@controller
heat_metadata_server_url = http://controller:8000
heat_waitcondition_server_url = http://controller:8000/v1/waitcondition
stack_domain_admin = heat_domain_admin
stack_domain_admin_password = $HEAT_DOMAIN_PASS
stack_user_domain_name = heat

[keystone_authtoken]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = heat
password = $HEAT_PASS

[trustee]
auth_type = password
auth_url = http://controller:5000
username = heat
password = $HEAT_PASS
user_domain_name = default

[clients_keystone]
auth_uri = http://controller:5000
EOF
su -s /bin/sh -c "heat-manage db_sync" heat
service heat-api restart
service heat-api-cfn restart
service heat-engine restart
sleep 10s

source ~/admin-openrc
openstack orchestration service list

apt -y install python-heat-dashboard
service apache2 restart

