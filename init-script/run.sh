#!/bin/sh

rm -rf /var/lib/mysql/lost+found
rm -rf /run-scripts/*
#mkdir "/var/lib/mysql/"
cp /tmp/scripts/* /scripts
