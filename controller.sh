#!/bin/bash -x

if [ "$#" -ne 1 ]; then
    export IP_ADDR=$(hostname -i)
else
    export IP_ADDR=$1
fi

export DEBIAN_FRONTEND=noninteractive

source passwords.sh

apt -y install python3-openstackclient

apt -y install mariadb-server python3-pymysql

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

mysql -sfu root <<EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
EOF

apt -y install rabbitmq-server
rabbitmqctl add_user openstack $RABBIT_PASS
rabbitmqctl set_permissions openstack ".*" ".*" ".*"

apt -y install memcached python3-memcache
sed -i "s/127\.0\.0\.1/$IP_ADDR/g" /etc/memcached.conf
service memcached restart

apt -y install etcd
mkdir -p /etc/etcd
cat > /etc/etcd/etcd.conf.yml <<EOF
name: controller
data-dir: /var/lib/etcd
initial-cluster-state: 'new'
initial-cluster-token: 'etcd-cluster-01'
initial-cluster: controller=http://$IP_ADDR:2380
initial-advertise-peer-urls: http://$IP_ADDR:2380
advertise-client-urls: http://$IP_ADDR:2379
listen-peer-urls: http://0.0.0.0:2380
listen-client-urls: http://$IP_ADDR:2379
EOF

cat > /lib/systemd/system/etcd.service <<EOF
[Unit]
After=network.target
Description=etcd - highly-available key value store

[Service]
LimitNOFILE=65536
Restart=on-failure
Type=notify
ExecStart=/usr/bin/etcd --config-file /etc/etcd/etcd.conf.yml
User=etcd

[Install]
WantedBy=multi-user.target
EOF
systemctl enable etcd
systemctl start etcd
