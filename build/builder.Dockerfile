FROM debian:bookworm-slim AS builder

ARG ZIG_VERSION="0.15.1"

RUN apt-get update -y && \
    apt-get install -yq --no-install-recommends \
    build-essential \
    ca-certificates \
    curl && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/apt/archive/*.deb

RUN curl https://raw.githubusercontent.com/tristanisham/zvm/master/install.sh | bash
RUN /root/.zvm/self/zvm i --zls --full "${ZIG_VERSION}"

FROM debian:bookworm-slim

ENV TAG=""
ENV TARGET="x86_64-linux-gnu"
ENV OUT_NAME="libscrapli-x86_64-linux-gnu.so.${TAG}"

COPY --from=builder /root/.zvm/bin/zig /usr/bin/zig
COPY --from=builder /root/.zvm/bin/lib /lib

RUN apt-get update -y && \
    apt-get install -yq --no-install-recommends \
    build-essential \
    ca-certificates \
    git && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /var/cache/apt/archive/*.deb

WORKDIR /build

COPY builder.sh .

ENTRYPOINT ["/build/builder.sh"]
