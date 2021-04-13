FROM tianon/toybox:0.8.4

COPY peer-finder /tmp/scripts/peer-finder

COPY scripts /tmp/scripts
COPY init-script /init-script

ENTRYPOINT ["/init-script/run.sh"]
