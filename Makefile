SHELL=/bin/bash -o pipefail

REGISTRY ?= kubedb
BIN      := mysql-init
IMAGE    := $(REGISTRY)/$(BIN)
#TAG      := $(shell git describe --exact-match --abbrev=0 2>/dev/null || echo "")
TAG :=8.0.27
.PHONY: push
push: container
	docker push $(IMAGE):$(TAG)

.PHONY: container
container:
	wget -qO tini https://github.com/kubedb/tini/releases/download/v0.20.0/tini-static
	chmod +x tini
	chmod +x init-script/run.sh
	find $$(pwd)/scripts -type f -exec chmod +x {} \;
	docker build --pull -t $(IMAGE):$(TAG) .
	rm tini

.PHONY: version
version:
	@echo ::set-output name=version::$(TAG)

.PHONY: fmt
fmt:
	@find . -path ./vendor -prune -o -name '*.sh' -exec shfmt -l -w -ci -i 4 {} \;

.PHONY: verify
verify: fmt
	@if !(git diff --exit-code HEAD); then \
		echo "files are out of date, run make fmt"; exit 1; \
	fi

.PHONY: ci
ci: verify

# make and load docker image to kind cluster
.PHONY: push-to-kind
push-to-kind: container
	@echo "Loading docker image into kind cluster...."
	@kind load docker-image $(IMAGE):$(TAG)
	@echo "Image has been pushed successfully into kind cluster."