#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
VERSION=${HARBOR_TEST_VERSION:-2.15.2}
WORK=$(mktemp -d)
cleanup() { sudo rm -rf "$WORK"; }
trap cleanup EXIT

archive="$WORK/harbor-online-installer.tgz"
url="https://github.com/goharbor/harbor/releases/download/v${VERSION}/harbor-online-installer-v${VERSION}.tgz"
printf 'Downloading Harbor %s online installer...\n' "$VERSION"
curl --fail --location --retry 5 --retry-delay 2 -o "$archive" "$url"
mkdir -p "$WORK/harbor"
tar -xzf "$archive" --strip-components=1 -C "$WORK/harbor"

mkdir -p "$WORK/data" "$WORK/logs" "$WORK/tls"
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 \
  -subj '/CN=harbor.example.com' \
  -keyout "$WORK/tls/harbor.example.com.key" \
  -out "$WORK/tls/harbor.example.com.crt" >/dev/null 2>&1
chmod 0600 "$WORK/tls/harbor.example.com.key"

export HARBOR_DB_PASSWORD='ci-db-secret'
export HARBOR_S3_ACCESS_KEY='ci-access-key'
export HARBOR_S3_SECRET_KEY='ci-secret-key'
export HARBOR_ADMIN_PASSWORD='ci-admin-secret'

python3 "$ROOT/debian/harbor/lib/render_config.py" \
  --template "$WORK/harbor/harbor.yml.tmpl" \
  --output "$WORK/harbor/harbor.yml" \
  --hostname harbor.example.com \
  --data-volume "$WORK/data" \
  --log-location "$WORK/logs" \
  --db-host postgres.example.com \
  --db-port 5432 \
  --db-name harbor \
  --db-user harbor \
  --db-ssl-mode require \
  --s3-endpoint https://s3.example.com \
  --s3-bucket harbor \
  --s3-region us-east-1 \
  --s3-force-path-style \
  --tls-cert "$WORK/tls/harbor.example.com.crt" \
  --tls-key "$WORK/tls/harbor.example.com.key"

printf 'Running Harbor official prepare...\n'
(
  cd "$WORK/harbor"
  ./prepare
  sudo docker compose -f docker-compose.yml config >/dev/null
)

services=$(sudo docker compose -f "$WORK/harbor/docker-compose.yml" config --services)
if grep -Eq '^(database|postgresql)$' <<<"$services"; then
  printf 'FAIL: local PostgreSQL service exists despite external_database configuration\n' >&2
  exit 1
fi

sudo python3 - "$WORK/harbor/common/config/registry/config.yml" "$WORK/harbor/harbor.yml" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as fh:
    registry = yaml.safe_load(fh)
with open(sys.argv[2], encoding='utf-8') as fh:
    harbor = yaml.safe_load(fh)
storage = registry.get('storage') or {}
assert 's3' in storage, storage
assert 'filesystem' not in storage, storage
s3 = storage['s3']
assert s3['bucket'] == 'harbor', s3
assert s3['regionendpoint'] == 'https://s3.example.com', s3
assert s3['forcepathstyle'] is True, s3
assert harbor['external_database']['harbor']['host'] == 'postgres.example.com'
assert harbor['external_database']['harbor']['ssl_mode'] == 'require'
assert 'filesystem' not in harbor['storage_service']
PY

printf 'Harbor official prepare integration: PASS\n'
