#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 IMAGE" >&2
    exit 2
fi

if ! command -v qemu-aarch64 >/dev/null 2>&1; then
    echo "ERROR: qemu-aarch64 is required." >&2
    exit 1
fi

image=$1
work_dir=$(mktemp -d)
extract_container=
server_pid=

cleanup() {
    status=$?
    trap - 0
    if [ -n "$server_pid" ]; then
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" >/dev/null 2>&1 || true
    fi
    if [ -n "$extract_container" ]; then
        docker rm -f "$extract_container" >/dev/null 2>&1 || true
    fi
    rm -rf "$work_dir"
    exit "$status"
}
trap cleanup 0

page_size=$(qemu-aarch64 -p 16384 /usr/bin/getconf PAGESIZE)
if [ "$page_size" != 16384 ]; then
    echo "ERROR: QEMU page size is $page_size bytes, expected 16384." >&2
    exit 1
fi

extract_container=$(docker create "$image")
docker cp "$extract_container:/usr/bin/redis-server" "$work_dir/redis-server"
docker cp "$extract_container:/usr/bin/redis-cli" "$work_dir/redis-cli"
docker rm "$extract_container" >/dev/null
extract_container=

version=$(qemu-aarch64 -p 16384 "$work_dir/redis-server" --version)
printf '%s\n' "$version" | grep -F "v=8.10.1"
printf '%s\n' "$version" | grep -F "malloc=libc"

socket="$work_dir/redis.sock"
qemu-aarch64 -p 16384 "$work_dir/redis-server" \
    --save "" \
    --appendonly no \
    --port 0 \
    --unixsocket "$socket" \
    --unixsocketperm 700 \
    >"$work_dir/redis.log" 2>&1 &
server_pid=$!

attempt=0
while [ ! -S "$socket" ]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        cat "$work_dir/redis.log" >&2
        echo "ERROR: Redis exited during QEMU 16 KiB startup." >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 50 ]; then
        cat "$work_dir/redis.log" >&2
        echo "ERROR: Redis did not create its socket within 5 seconds." >&2
        exit 1
    fi
    sleep 0.1
done

response=$(qemu-aarch64 -p 16384 "$work_dir/redis-cli" -s "$socket" ping)
if [ "$response" != PONG ]; then
    echo "ERROR: expected PONG from QEMU Redis, got: $response" >&2
    exit 1
fi

echo "PASS: the image's Redis binary starts and returns PONG with QEMU page size 16384."
