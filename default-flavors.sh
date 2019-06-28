#!/bin/bash -x
openstack flavor create --id 0 --vcpus 1 --disk 1 --ram 64 m1.nano
openstack flavor create --id 1 --vcpus 1 --disk 1 --ram 512 m1.tiny

openstack flavor create --id 2 --vcpus 1 --disk 20 --ram 2048 m1.small
openstack flavor create --id 3 --vcpus 2 --disk 40 --ram 4096 m1.medium
openstack flavor create --id 4 --vcpus 4 --disk 80 --ram 8192 m1.large
openstack flavor create --id 5 --vcpus 8 --disk 160 --ram 16384 m1.xlarge
openstack flavor create --id 6 --vcpus 16 --disk 160 --ram 32768 m1.2xlarge
openstack flavor create --id 7 --vcpus 32 --disk 160 --ram 65536 m1.4xlarge

openstack flavor create --id 12 --vcpus 1 --disk 5 --ram 2048 c1.small
openstack flavor create --id 13 --vcpus 2 --disk 10 --ram 4096 c1.medium
openstack flavor create --id 14 --vcpus 4 --disk 20 --ram 8192 c1.large
openstack flavor create --id 15 --vcpus 8 --disk 40 --ram 16384 c1.xlarge
openstack flavor create --id 16 --vcpus 16 --disk 40 --ram 32768 c1.2xlarge
openstack flavor create --id 17 --vcpus 32 --disk 40 --ram 65536 c1.4xlarge
