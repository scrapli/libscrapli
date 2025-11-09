.DEFAULT_GOAL := help

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

fmt: ## Format all zig files
	zig fmt ./

lint: ## Lint all zig files
	zlint -V

test: fmt ## Run unit tests
	zig build test --summary all -Doptimize=Debug

test-integration: fmt ## Run integration tests
	zig build test --summary all -Doptimize=Debug -- --integration

test-functional: fmt ## Run functional tests
	zig build test --summary all -Doptimize=Debug -- --functional

test-functional-ci: fmt ## Run functional tests (w/ limited ci platforms); ensures TERM set, since this is normally unset in GH actions
	TERM=screen-256color zig build test --summary all -Doptimize=Debug -- --functional --ci

test-coverage: fmt ## Run integration tests plus coverage (goes to zig-out/cover)
	rm -rf zig-out/cover || true
	zig build test --summary all -- --integration --coverage

open-coverage: ## Open the generated coverage report
	open zig-out/cover/index.html

clean-zig-cache: ## Nukes the local zig cache dir if its > 16gb
	bash -c "[ -d .zig-cache ] && [ $$(du -s .zig-cache | awk '{print $$1}') -gt $$((16 * 1024 * 1024)) ] && rm -rf .zig-cache" || true

build: fmt clean-zig-cache ## Build the shared objects.
	zig build ffi -freference-trace=4 --summary all

build-release: fmt clean-zig-cache ## Build the shared objects w/ release optimization
	rm -rf zig-out && zig build ffi -Doptimize=ReleaseSmall -freference-trace=4 --summary all -- --all-targets
	find zig-out -type f \( -name 'libscrapli.*.dylib' -o -name 'libscrapli.so.*' \) -exec sha256sum {} + > "zig-out/checksums.txt"

build-examples: fmt clean-zig-cache ## Build the example binaries
	zig build -freference-trace=4 --summary all -- --examples --skip-ffi-lib

build-main: fmt clean-zig-cache ## Build the "main" binary in repo root, useful for testing stuff out
	zig build main -Doptimize=ReleaseSafe -freference-trace=4 --summary all

run-main: fmt build-main ## Build and run the "main" binary in repo root
	./zig-out/bin/scrapli

run-clab: ## Runs the clab functional testing topo; uses the clab launcher to run nicely on darwin
	rm -r .clab/* || true
	docker network rm clab || true
	docker network create \
		--driver bridge \
		--subnet=172.20.20.0/24 \
		--gateway=172.20.20.1 \
		--ipv6 \
		--subnet=2001:172:20:20::/64 \
		--gateway=2001:172:20:20::1 \
		--opt com.docker.network.driver.mtu=65535 \
		--label containerlab \
		clab
	docker run \
		-d \
		--rm \
		--name clab-launcher \
		--platform=linux/arm64 \
		--privileged \
		--pid=host \
		--stop-signal=SIGINT \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v /run/netns:/run/netns \
		-v "$$(pwd):$$(pwd)" \
		-e "WORKDIR=$$(pwd)/.clab" \
		-e "HOST_ARCH=$$(uname -m)" \
		ghcr.io/scrapli/scrapli_clab/launcher:0.0.7

run-clab-ci: ## Runs the clab functional testing topo with the ci specific topology - omits ceos
	mkdir .clab || true
	rm -r .clab/* || true
	docker network rm clab || true
	docker network create \
	    --driver bridge \
	    --subnet=172.20.20.0/24 \
	    --gateway=172.20.20.1 \
	    --ipv6 \
	    --subnet=2001:172:20:20::/64 \
	    --gateway=2001:172:20:20::1 \
	    --opt com.docker.network.driver.mtu=65535 \
	    --label containerlab \
	    clab
	docker run \
        -d \
        --rm \
        --name clab-launcher \
        --privileged \
        --pid=host \
        --stop-signal=SIGINT \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v /run/netns:/run/netns \
        -v "$$(pwd):$$(pwd)" \
        -e "WORKDIR=$$(pwd)/.clab" \
        -e "HOST_ARCH=$$(uname -m)" \
        -e "CLAB_TOPO=topo.ci.$$(uname -m).yaml" \
        ghcr.io/scrapli/scrapli_clab/launcher:0.0.7
