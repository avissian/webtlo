#!/bin/bash
set -euo pipefail

image="${1:?Usage: bash docker/smoke-test.sh IMAGE}"
container="webtlo-smoke-$$"

cleanup() {
    result=$?
    if [ "$result" -ne 0 ]; then
        docker logs "$container" || true
    fi
    docker rm --force --volumes "$container" >/dev/null || true
    exit "$result"
}
trap cleanup EXIT

docker run --detach --name "$container" \
    --publish 127.0.0.1::80 \
    --env WEBTLO_CRON=false \
    "$image"

docker exec "$container" nginx -t
docker exec "$container" php-fpm84 -t

# This diagnostic exists only in the disposable test container, not the image.
docker exec --interactive "$container" sh -c 'cat > public/_docker_smoke.php' <<'PHP'
<?php
header('Content-Type: application/json');
echo json_encode([
    'version' => PHP_VERSION,
    'version_id' => PHP_VERSION_ID,
    'sapi' => PHP_SAPI,
    'ini' => php_ini_loaded_file(),
    'memory_limit' => ini_get('memory_limit'),
    'session_loaded' => extension_loaded('session'),
    'upload_progress' => ini_get('session.upload_progress.enabled'),
    'extensions' => get_loaded_extensions(),
]);
PHP

address="$(docker port "$container" 80/tcp)"
url="http://$address"
ready=false
for ((attempt = 0; attempt < 60; attempt++)); do
    if curl --fail --silent --max-time 3 --output /dev/null "$url/_docker_smoke.php"; then
        ready=true
        break
    fi
    sleep 1
done
if [ "$ready" != true ]; then
    echo 'nginx/PHP-FPM did not become ready' >&2
    exit 1
fi

curl --fail --silent --show-error --max-time 15 "$url/_docker_smoke.php" |
    docker exec --interactive "$container" php -r '
        $data = json_decode(stream_get_contents(STDIN), true, 512, JSON_THROW_ON_ERROR);
        echo json_encode($data, JSON_PRETTY_PRINT), PHP_EOL;
        if ($data["version_id"] < 80427 || $data["version_id"] >= 80500
            || $data["sapi"] !== "fpm-fcgi"
            || $data["ini"] !== "/etc/php84/php.ini"
            || $data["memory_limit"] !== "2G"
            || ($data["session_loaded"] && (bool) $data["upload_progress"])) {
            fwrite(STDERR, "Unexpected PHP-FPM runtime configuration\n");
            exit(1);
        }
        $required = ["curl", "dom", "libxml", "mbstring", "PDO", "pdo_sqlite",
            "sqlite3", "xml", "zlib", "openssl", "iconv", "Phar"];
        $missing = array_diff($required, $data["extensions"]);
        if ($missing) {
            fwrite(STDERR, "Missing extensions: " . implode(", ", $missing) . "\n");
            exit(1);
        }
    '

# Rendering the actual application also exercises autoloading and a fresh SQLite DB.
html="$(curl --fail --silent --show-error --max-time 30 "$url/")"
if [[ "$html" != *'<title>web-TLO-'* ]]; then
    printf '%s\n' "$html" >&2
    echo 'WebTLO did not render its main page' >&2
    exit 1
fi

echo 'Docker smoke test passed'
