#!/usr/bin/env bash

file="/var/lib/mysql/join-in-cluster"

if [ -e "$file" ]; then
    echo -n "Not Empty"
else
    echo -n "Empty"
fi