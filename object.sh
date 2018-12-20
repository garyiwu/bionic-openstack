#!/bin/bash -x

# need to manually mount the storage under /srv/node/sdb

if [ "$#" -ne 1 ]; then
    export IP_ADDR=$(hostname -I | cut -d' ' -f1)
else
    export IP_ADDR=$1
fi

export DEBIAN_FRONTEND=noninteractive

source passwords.sh

add-apt-repository -y cloud-archive:pike
apt-get update
apt-get -y dist-upgrade


apt-get -y install crudini

apt-get -y install rsync

cat > /etc/rsyncd.conf <<EOF
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = $IP_ADDR

[account]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/account.lock

[container]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/container.lock

[object]
max connections = 2
path = /srv/node/
read only = False
lock file = /var/lock/object.lock
EOF

sed -i 's/RSYNC_ENABLE=.*/RSYNC_ENABLE=true/g' /etc/default/rsync
service rsync start

apt-get -y install swift swift-account swift-container swift-object
curl -o /etc/swift/account-server.conf https://git.openstack.org/cgit/openstack/swift/plain/etc/account-server.conf-sample?h=stable/pike
curl -o /etc/swift/container-server.conf https://git.openstack.org/cgit/openstack/swift/plain/etc/container-server.conf-sample?h=stable/pike
curl -o /etc/swift/object-server.conf https://git.openstack.org/cgit/openstack/swift/plain/etc/object-server.conf-sample?h=stable/pike

crudini --merge /etc/swift/account-server.conf <<EOF
[DEFAULT]
bind_ip = $IP_ADDR
bind_port = 6202
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon account-server

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
EOF

crudini --merge /etc/swift/container-server.conf <<EOF
[DEFAULT]
bind_ip = $IP_ADDR
bind_port = 6201
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon container-server

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
EOF

crudini --merge /etc/swift/object-server.conf <<EOF
[DEFAULT]
bind_ip = $IP_ADDR
bind_port = 6200
user = swift
swift_dir = /etc/swift
devices = /srv/node
mount_check = True

[pipeline:main]
pipeline = healthcheck recon object-server

[filter:recon]
use = egg:swift#recon
recon_cache_path = /var/cache/swift
recon_lock_path = /var/lock
EOF

chown -R swift:swift /srv/node
mkdir -p /var/cache/swift
chown -R root:swift /var/cache/swift
chmod -R 775 /var/cache/swift
