SHELL=/bin/bash -o pipefail

REGISTRY ?= kubedb
BIN      := mysql-init
IMAGE    := $(REGISTRY)/$(BIN)
TAG      := $(shell git describe --exact-match --abbrev=0 2>/dev/null || echo "")


.PHONY: push
push: container
	docker push $(IMAGE):$(TAG)

.PHONY: container
container:
	curl -fsSL -O https://github.com/kmodules/peer-finder/releases/download/v1.1.0/peer-finder-linux-amd64.tar.gz
	tar -xzvf peer-finder-linux-amd64.tar.gz
	mv peer-finder-linux-amd64 peer-finder
	chmod +x peer-finder
	chmod +x init-script/run.sh
	find $$(pwd)/scripts -type f -exec chmod +x {} \;
	docker build --pull -t $(IMAGE):$(TAG) .
	rm peer-finder peer-finder-linux-amd64.tar.gz

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