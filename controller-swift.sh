#!/bin/bash -x

# export PROVIDER_INTERFACE_NAME=$(ip -o -4 route show to default | awk '{print $5}')
# the provider interface is the 2nd interface that doesn't have an IP yet
export PROVIDER_INTERFACE_NAME=eno2

# this sample assumes only a single swift storage node named "storage"; ensure that it exists in /etc/hosts
export SWIFT_NODE_IP_ADDR=$(getent hosts storage | awk '{ print $1 }')

if [ "$#" -ne 1 ]; then
    export IP_ADDR=$(hostname -I | cut -d' ' -f1)
else
    export IP_ADDR=$1
fi

export DEBIAN_FRONTEND=noninteractive

source passwords.sh


add-apt-repository -y cloud-archive:pike
apt update
apt-get -y dist-upgrade


apt-get -y install python-openstackclient crudini


#
# Swift
#
source ~/admin-openrc
openstack user create --domain default --password $SWIFT_PASS swift
openstack role add --project service --user swift admin
openstack service create --name swift --description "OpenStack Object Storage" object-store
openstack endpoint create --region RegionOne object-store public http://controller:8080/v1/AUTH_%\(project_id\)s
openstack endpoint create --region RegionOne object-store internal http://controller:8080/v1/AUTH_%\(project_id\)s
openstack endpoint create --region RegionOne object-store admin http://controller:8080/v1

apt-get -y install swift swift-proxy python-swiftclient \
  python-keystoneclient python-keystonemiddleware \
  memcached

mkdir -p /etc/swift
curl -L -o /etc/swift/proxy-server.conf https://git.openstack.org/cgit/openstack/swift/plain/etc/proxy-server.conf-sample?h=stable/pike
cd /etc
git add swift
git commit -a -m "swift original config"

crudini --merge /etc/swift/proxy-server.conf <<EOF
[DEFAULT]
bind_port = 8080
user = swift
swift_dir = /etc/swift

[pipeline:main]
pipeline = catch_errors gatekeeper healthcheck proxy-logging cache container_sync bulk ratelimit authtoken keystoneauth container-quotas account-quotas slo dlo versioned_writes proxy-logging proxy-server

[app:proxy-server]
use = egg:swift#proxy
account_autocreate = True

[filter:keystoneauth]
use = egg:swift#keystoneauth
operator_roles = admin,user

[filter:authtoken]
paste.filter_factory = keystonemiddleware.auth_token:filter_factory
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_id = default
user_domain_id = default
project_name = service
username = swift
password = $SWIFT_PASS
delay_auth_decision = True

[filter:cache]
use = egg:swift#memcache
memcache_servers = controller:11211
EOF

cd /etc
git commit -a -m "swift config complete"
cd ~

# this sample assumes only a single swift storage node named "storage", that has only a single device "sdb"
cd /etc/swift

swift-ring-builder account.builder create 10 1 1
swift-ring-builder account.builder add \
  --region 1 --zone 1 --ip $SWIFT_NODE_IP_ADDR --port 6202 --device sdb --weight 100
swift-ring-builder account.builder
swift-ring-builder account.builder rebalance

swift-ring-builder container.builder create 10 1 1
swift-ring-builder container.builder add \
  --region 1 --zone 1 --ip $SWIFT_NODE_IP_ADDR --port 6201 --device sdb --weight 100
swift-ring-builder container.builder
swift-ring-builder container.builder rebalance

swift-ring-builder object.builder create 10 1 1
swift-ring-builder object.builder add \
  --region 1 --zone 1 --ip $SWIFT_NODE_IP_ADDR --port 6200 --device sdb --weight 100
swift-ring-builder object.builder
swift-ring-builder object.builder rebalance

curl -L -o /etc/swift/swift.conf \
  https://git.openstack.org/cgit/openstack/swift/plain/etc/swift.conf-sample?h=stable/pike
crudini --merge /etc/swift/swift.conf <<EOF
[swift-hash]
swift_hash_path_suffix = $SWIFT_HASH_PATH_SUFFIX
swift_hash_path_prefix = $SWIFT_HASH_PATH_PREFIX

[storage-policy:0]
name = Policy-0
default = yes
EOF

cd /etc
git add -A
git commit -a -m "swift ring config complete"
cd ~


chown -R root:swift /etc/swift
service memcached restart
service swift-proxy restart
