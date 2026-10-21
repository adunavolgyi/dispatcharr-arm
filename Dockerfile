# syntax=docker/dockerfile:1

ARG UPSTREAM_IMAGE=ghcr.io/dispatcharr/dispatcharr:0.32.0@sha256:dce6a6617b23b221eac59e69544995e2a2c52906da05e41cf367145bf3c4e167
ARG UPSTREAM_VERSION=0.32.0
ARG UPSTREAM_DIGEST=sha256:dce6a6617b23b221eac59e69544995e2a2c52906da05e41cf367145bf3c4e167

FROM ${UPSTREAM_IMAGE} AS redis-builder

ARG REDIS_VERSION=8.10.1
ARG REDIS_SHA256=60166c95ab7aedaa9dfe516de685be0a4dd87be95ded59ba429df14c13f1b663

RUN test "$(dpkg --print-architecture)" = "arm64" \
    && test "$(command -v redis-server)" = "/usr/bin/redis-server" \
    && dpkg-query -W -f='${Version}\n' redis-server | grep -F ':8.10.1-' \
    && test "$(readlink -f /usr/bin/redis-check-aof)" = "/usr/bin/redis-server" \
    && test "$(readlink -f /usr/bin/redis-check-rdb)" = "/usr/bin/redis-server" \
    && apt-get update \
    && apt-get install --no-install-recommends -y build-essential \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSLo /tmp/redis.tar.gz "https://download.redis.io/releases/redis-${REDIS_VERSION}.tar.gz" \
    && echo "${REDIS_SHA256}  /tmp/redis.tar.gz" | sha256sum -c - \
    && mkdir /tmp/redis \
    && tar -xzf /tmp/redis.tar.gz --strip-components=1 -C /tmp/redis \
    && make -C /tmp/redis -j"$(nproc)" MALLOC=libc build redis \
    && install -D -m 0755 /tmp/redis/src/redis-server /out/redis-server \
    && strip /out/redis-server \
    && /out/redis-server --version | grep -F "v=${REDIS_VERSION}" \
    && /out/redis-server --version | grep -F "malloc=libc"

FROM ${UPSTREAM_IMAGE}

ARG UPSTREAM_VERSION
ARG UPSTREAM_DIGEST

COPY --from=redis-builder /out/redis-server /usr/bin/redis-server

LABEL org.opencontainers.image.title="Dispatcharr AIO for 16 KiB ARM64 kernels" \
      org.opencontainers.image.source="https://github.com/adunavolgyi/dispatcharr-arm" \
      org.opencontainers.image.version="${UPSTREAM_VERSION}" \
      org.opencontainers.image.base.name="ghcr.io/dispatcharr/dispatcharr:${UPSTREAM_VERSION}" \
      org.opencontainers.image.base.digest="${UPSTREAM_DIGEST}"

RUN test "$(dpkg --print-architecture)" = "arm64" \
    && test "$(command -v redis-server)" = "/usr/bin/redis-server" \
    && test "$(readlink -f /usr/bin/redis-check-aof)" = "/usr/bin/redis-server" \
    && test "$(readlink -f /usr/bin/redis-check-rdb)" = "/usr/bin/redis-server" \
    && redis-server --version | grep -F "v=8.10.1" \
    && redis-server --version | grep -F "malloc=libc"
