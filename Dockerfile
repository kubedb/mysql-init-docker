FROM alpine

COPY scripts /tmp/scripts
COPY init-script /init-script
COPY tini /tmp/scripts/tini

ENTRYPOINT ["/init-script/run.sh"]
