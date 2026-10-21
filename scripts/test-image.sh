#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 IMAGE" >&2
    exit 2
fi

image=$1
container="dispatcharr-aio-test-$$"
started=false

cleanup() {
    status=$?
    trap - 0
    if [ "$started" = true ]; then
        if [ "$status" -ne 0 ]; then
            docker logs "$container" 2>&1 || true
        fi
        docker rm -f "$container" >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup 0

architecture=$(uname -m)
page_size=$(getconf PAGESIZE)
echo "Test host: architecture=$architecture page_size=$page_size"

if [ "$architecture" != "aarch64" ]; then
    echo "ERROR: the image tests require a native ARM64 host." >&2
    exit 1
fi

if [ -n "${REQUIRE_PAGE_SIZE:-}" ] && [ "$page_size" != "$REQUIRE_PAGE_SIZE" ]; then
    echo "ERROR: host page size is $page_size bytes, expected $REQUIRE_PAGE_SIZE." >&2
    exit 1
fi

docker run --detach \
    --name "$container" \
    --tmpfs /data:rw,nosuid,nodev \
    --env DISPATCHARR_ENV=aio \
    --env REDIS_HOST=localhost \
    --env CELERY_BROKER_URL=redis://localhost:6379/0 \
    --env DISPATCHARR_DEBUG=true \
    --env UWSGI_WORKERS=1 \
    --env CELERY_MAX_WORKERS=1 \
    --env CELERY_MIN_WORKERS=1 \
    "$image" >/dev/null
started=true

attempt=0
until docker exec "$container" curl -fsS \
    http://127.0.0.1:9191/api/accounts/initialize-superuser/ >/dev/null 2>&1; do
    if [ "$(docker inspect --format '{{.State.Running}}' "$container")" != "true" ]; then
        echo "ERROR: Dispatcharr exited during initialization." >&2
        exit 1
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 150 ]; then
        echo "ERROR: Dispatcharr did not initialize within 5 minutes." >&2
        exit 1
    fi
    sleep 2
done

docker exec "$container" sh -c '
    test "$(command -v redis-server)" = /usr/bin/redis-server
    test "$(readlink -f /usr/bin/redis-check-aof)" = /usr/bin/redis-server
    test "$(readlink -f /usr/bin/redis-check-rdb)" = /usr/bin/redis-server
    redis-server --version | grep -F "v=8.10.1"
    redis-server --version | grep -F "malloc=libc"
    pgrep -f redis-server >/dev/null
    pgrep -f "celery .*worker" >/dev/null
    pg_isready -q
'

response=$(docker exec "$container" redis-cli ping)
if [ "$response" != "PONG" ]; then
    echo "ERROR: expected PONG from Redis, got: $response" >&2
    exit 1
fi

password=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
setup_response=$(docker exec "$container" curl -fsS \
    -H 'Content-Type: application/json' \
    --data-binary "{\"username\":\"ciadmin\",\"password\":\"$password\"}" \
    http://127.0.0.1:9191/api/accounts/initialize-superuser/)
printf '%s' "$setup_response" | grep -Eq '"superuser_exists"[[:space:]]*:[[:space:]]*true'

token_response=$(docker exec "$container" curl -fsS \
    -H 'Content-Type: application/json' \
    --data-binary "{\"username\":\"ciadmin\",\"password\":\"$password\"}" \
    http://127.0.0.1:9191/api/accounts/token/)
access_token=$(printf '%s' "$token_response" | docker exec -i "$container" \
    python3 -c 'import json, sys; print(json.load(sys.stdin)["access"])')

user_response=$(docker exec "$container" curl -fsS \
    -H "Authorization: Bearer $access_token" \
    http://127.0.0.1:9191/api/accounts/users/me/)
printf '%s' "$user_response" | grep -Eq '"username"[[:space:]]*:[[:space:]]*"ciadmin"'

echo "PASS: Redis startup, PING, AIO initialization, and authentication API checks succeeded."
if [ "${REQUIRE_PAGE_SIZE:-}" = "16384" ]; then
    echo "PASS: real-device ARM64 16 KiB page-size compatibility is confirmed."
else
    echo "NOTICE: this is a normal ARM64 test, not proof of 16 KiB Raspberry Pi compatibility."
fi
