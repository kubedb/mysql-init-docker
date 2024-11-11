#!/bin/sh

rm -rf /var/lib/mysql/lost+found
rm -rf /run-scripts/*
rm /var/lib/mysql/auto.cnf
cp /tmp/scripts/* /scripts

