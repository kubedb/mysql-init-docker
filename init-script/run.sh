#!/bin/sh

rm -rf /var/lib/mysql/lost+found

cp /tmp/scripts/peer-finder /scripts/peer-finder
cp /tmp/scripts/"$INIT_IMAGE_TAG"/* /scripts
