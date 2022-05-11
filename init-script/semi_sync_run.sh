#!/bin/sh

rm -rf /var/lib/mysql/lost+found
rm -rf /var/lib/mysql/data/lost+found
rm -rf /run-scripts/*
cp /tmp/scripts/* /scripts

if [ ! -d "/var/lib/mysql/raftwal" ]; then
    mkdir -p /var/lib/mysql/data
    cd /var/lib/mysql
    # move all files into the data directory
    mv $(ls | grep -wv 'data') data/
fi
echo "complete initialization."
