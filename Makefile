.DEFAULT_GOAL := help

 ## Show this help
help:
	@awk -f build/makefile-doc.awk $(MAKEFILE_LIST)

##@ Housekeeping
## Nukes the zig-out dir
clean-zig-out:
	rm -rf zig-out

## Nukes the local zig cache dir if its > 16gb
clean-zig-cache:
	@if [ -d .zig-cache ]; then \
		size_kb=$$(du -s .zig-cache | cut -f1); \
		limit_kb=$$((16 * 1024 * 1024)); \
		if [ $$size_kb -gt $$limit_kb ]; then \
			echo "removing .zig-cache (size: $$size_kb KB > $$limit_kb KB)"; \
			rm -rf .zig-cache; \
		fi; \
	fi

##@ Development
## Format all zig files
fmt:
	zig fmt ./

## Lint all zig files
lint:
	zlint -V

##@ Testing
## Run unit tests
test: fmt
	zig build test \
	    -Doptimize=Debug \
		--summary all

## Run integration tests
test-integration: fmt
	zig build test \
	    -Doptimize=Debug \
		-Dintegration-tests=true \
		--summary all

## Run functional tests
test-functional: fmt
	zig build test \
	    -Doptimize=Debug \
		-Dfunctional-tests=true \
		--summary all

## Run functional tests (w/ limited ci platforms);
## ensures TERM set, since this is normally unset in GH actions
test-functional-ci: fmt
	TERM=screen-256color zig build test \
		-Doptimize=Debug \
		-Dfunctional-tests=true \
		-Dci-functional-tests=true \
		--summary all

##@ Testing Coverage
## Run integration tests plus coverage (goes to zig-out/cover)
test-coverage: fmt
	rm -rf zig-out/cover || true
	zig build test \
	    -Dintegration-tests=true \
		-Dtest-coverage=true \
		--summary all

## Open the generated coverage report
open-coverage:
	open zig-out/cover/index.html

##@ Test Environment
## Runs the clab functional testing topo; uses the clab launcher to run nicely on darwin
run-clab:
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

## Runs the clab functional testing topo with the ci specific topology - omits ceos
run-clab-ci:
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

##@ Build
## Build the shared object for the local system w/ release optimization
build: fmt clean-zig-cache
	zig build ffi \
	    -Doptimize=ReleaseSafe \
		-freference-trace=4 \
		-Ddependency-linkage=static \
		--summary all

## Build all the shared objects w/ release optimization
build-release: fmt clean-zig-out clean-zig-cache
	zig build ffi \
	    -Doptimize=ReleaseSafe \
		-freference-trace=4 \
		-Ddependency-linkage=static \
		-Dall-targets=true \
		--summary all
	find zig-out -type f \
	    \( -name 'libscrapli.*.dylib' -o -name 'libscrapli.so.*' \) \
	    -exec sha256sum {} + \
	    > zig-out/checksums.txt

## Build the example binaries, uses Debug build so you get leak checking
build-examples: fmt clean-zig-cache
	zig build examples \
	    -Doptimize=Debug \
		-freference-trace=4 \
		-Ddependency-linkage=static \
		--summary all

## Build the "main" binary in repo root, uses Debug build so you get leak checking
build-main: fmt clean-zig-cache
	zig build main \
	    -Doptimize=Debug \
		-freference-trace=4 \
		-Ddependency-linkage=static \
		--summary all

## Build and run the "main" binary in repo root
run-main: fmt build-main
	./zig-out/bin/scrapli
