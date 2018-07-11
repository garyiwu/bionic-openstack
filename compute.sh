#!/bin/bash -x

if [ "$#" -ne 1 ]; then
    export IP_ADDR=$(hostname -i)
else
    export IP_ADDR=$1
fi

export DEBIAN_FRONTEND=noninteractive

source passwords.sh

apt -y install python3-openstackclient
