#!/bin/sh

rm -rf /var/lib/mysql/lost+found
rm -rf /run-scripts/*
cp /tmp/scripts/* /scripts
if [[ "$PITR_RESTORE" == "true" ]]; then
  if [[ "$HOSTNAME" != *"-0" ]]; then
    if [[ -f /var/lib/mysql/auto.cnf ]]; then
       rm /var/lib/mysql/auto.cnf
    fi
  fi
fi

