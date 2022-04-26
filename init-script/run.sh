#!/bin/sh

rm -rf /var/lib/mysql/lost+found
rm -rf /run-scripts/*
cp /tmp/scripts/* /scripts
