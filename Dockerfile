FROM alpine

ARG TARGETOS
ARG TARGETARCH

RUN set -x \
	&& apk add --update ca-certificates curl

RUN curl -fsSL -o tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static-${TARGETARCH} \
	&& chmod +x tini



FROM alpine

LABEL org.opencontainers.image.source https://github.com/kubedb/mysql-init-docker

RUN apk add --no-cache bash

COPY scripts /tmp/scripts
COPY init-script /init-script
COPY --from=0 /tini /tmp/scripts/tini

ENTRYPOINT ["/init-script/run.sh"]
