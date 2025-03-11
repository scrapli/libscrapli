.DEFAULT_GOAL := help

help:
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

fmt: ## Format all zig files
	zig fmt ./

lint: ## Lint all zig files
	zlint -V ./src

test: fmt ## Run unit tests
	zig build test --summary all

test-integration: fmt ## Run integration tests
	zig build test --summary all -- --integration

test-functional: fmt ## Run functional tests
	zig build test --summary all -- --functional

test-functional-ci: fmt ## Run functional tests (w/ limited ci platforms); ensures TERM set, since this is normally unset in GH actions
	TERM=screen-256color zig build test --summary all -- --functional --ci

test-coverage: fmt ## Run integration tests plus coverage (goes to zig-out/cover)
	rm -rf zig-out/cover || true
	zig build test --summary all -- --integration --coverage

open-coverage: ## Open the generated coverage report
	open zig-out/cover/index.html

build: fmt ## Build the shared objects.
	zig build -freference-trace --summary all

build-release: fmt ## Build the shared objects w/ release optimization
	zig build -freference-trace --summary all -- --release

build-examples: fmt ## Build the example binaries
	zig build -freference-trace --summary all -- --examples --skip-lib --skip-ffi-lib

build-main: fmt ## Build the "main" binary in repo root
	zig build -freference-trace --summary all -- --main --skip-lib --skip-ffi-lib

run-main: fmt build-main ## Build and run the "main" binary in repo root
	./zig-out/bin/scrapli

build-clab-launcher: ## Builds the clab launcher image
	docker build \
		-f src/tests/functional/clab/launcher/Dockerfile \
		-t clab-launcher:latest \
		src/tests/functional/clab/launcher

run-clab: ## Runs the clab functional testing topo; uses the clab launcher to run nicely on darwin
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
		-v "$$(pwd)/src/tests/functional/clab:$$(pwd)/src/tests/functional/clab" \
		-e "LAUNCHER_WORKDIR=$$(pwd)/src/tests/functional/clab" \
		-e "HOST_ARCH=$$(uname -m)" \
		clab-launcher:latest
