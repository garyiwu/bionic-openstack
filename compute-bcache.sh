#!/bin/bash -x

apt-get -y install bcache-tools

wipefs -a /dev/sdb1
wipefs -a /dev/sda3

make-bcache -B /dev/sdb1 -C /dev/sda3
mkfs.ext4 -T largefile -L nova-instances /dev/bcache0
echo writeback > /sys/block/bcache0/bcache/cache_mode
bcache-super-show /dev/sdb1
