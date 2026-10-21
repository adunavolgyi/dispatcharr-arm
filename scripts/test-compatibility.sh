#!/bin/sh
set -eu

if [ "$(uname -m)" != "aarch64" ]; then
    echo "ERROR: this compatibility test must run on an ARM64 host." >&2
    exit 1
fi

page_size=$(getconf PAGESIZE)
if [ "$page_size" != "16384" ]; then
    echo "ERROR: host page size is $page_size bytes, not 16384; this is not a Raspberry Pi 16 KiB compatibility result." >&2
    exit 1
fi

redis_version=$(docker exec dispatcharr redis-server --version)
case "$redis_version" in
    *"v=8.10.1"*"malloc=libc"*) ;;
    *)
        echo "ERROR: dispatcharr is not running the expected Redis 8.10.1 libc build: $redis_version" >&2
        exit 1
        ;;
esac

response=$(docker exec dispatcharr redis-cli ping)
if [ "$response" != "PONG" ]; then
    echo "ERROR: expected PONG from Redis, got: $response" >&2
    exit 1
fi

echo "PASS: Dispatcharr Redis returned PONG on an ARM64 host with a 16384-byte page size."
