#!/bin/bash -x
openstack flavor create --id 0 --vcpus 1 --ram 64 --disk 1 m1.nano
openstack flavor create --id 1 --vcpus 1 --disk 1 --ram 512 m1.tiny
openstack flavor create --id 2 --vcpus 1 --disk 20 --ram 2048 m1.small
openstack flavor create --id 3 --vcpus 2 --disk 40 --ram 4096 m1.small
openstack flavor create --id 3 --vcpus 2 --disk 40 --ram 4096 m1.medium
openstack flavor create --id 4 --vcpus 4 --disk 80 --ram 8192 m1.large
openstack flavor create --id 5 --vcpus 8 --disk 160 --ram 16384 m1.xlarge
