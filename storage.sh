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
# Cinder
#
apt -y install lvm2 thin-provisioning-tools
pvcreate /dev/sdb1
vgcreate cinder-volumes /dev/sdb1

apt -y install cinder-volume

crudini --merge /etc/cinder/cinder.conf <<EOF
[database]
connection = mysql+pymysql://cinder:$CINDER_DBPASS@controller/cinder

[DEFAULT]
transport_url = rabbit://openstack:$RABBIT_PASS@controller
auth_strategy = keystone
my_ip = $IP_ADDR
enabled_backends = lvm
glance_api_servers = http://controller:9292

[keystone_authtoken]
auth_url = http://controller:5000
memcached_servers = controller:11211
auth_type = password
project_domain_id = default
user_domain_id = default
project_name = service
username = cinder
password = $CINDER_PASS

[lvm]
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
volume_group = cinder-volumes
iscsi_protocol = iscsi
iscsi_helper = tgtadm

[oslo_concurrency]
lock_path = /var/lib/cinder/tmp
EOF

service tgt restart
service cinder-volume restart
