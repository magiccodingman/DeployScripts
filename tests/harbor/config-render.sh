#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/harbor.yml.tmpl" <<'EOF'
hostname: reg.mydomain.com
http:
  port: 80
https:
  port: 443
  certificate: /your/certificate/path
  private_key: /your/private/key/path
harbor_admin_password: Harbor12345
database:
  password: root123
data_volume: /data
jobservice:
  max_job_workers: 10
  max_job_duration_hours: 24
  job_loggers:
    - STD_OUTPUT
    - FILE
  logger_sweeper_duration: 1
notification:
  webhook_job_max_retry: 3
  webhook_job_http_client_timeout: 3
log:
  level: info
  local:
    rotate_count: 50
    rotate_size: 200M
    location: /var/log/harbor
_version: 2.15.0
EOF

export HARBOR_DB_PASSWORD='db-secret'
export HARBOR_S3_ACCESS_KEY='access-secret'
export HARBOR_S3_SECRET_KEY='s3-secret'
export HARBOR_ADMIN_PASSWORD='admin-secret'

python3 "$ROOT/debian/harbor/lib/render_config.py" \
  --template "$WORK/harbor.yml.tmpl" \
  --output "$WORK/harbor.yml" \
  --hostname harbor.example.com \
  --data-volume /srv/secure/harbor/data \
  --log-location /srv/secure/harbor/logs \
  --db-host postgres.example.com \
  --db-port 5432 \
  --db-name harbor \
  --db-user harbor \
  --db-ssl-mode require \
  --s3-endpoint https://s3.example.com \
  --s3-bucket harbor \
  --s3-region us-east-1 \
  --s3-force-path-style \
  --tls-cert /srv/secure/harbor/tls/harbor.example.com.crt \
  --tls-key /srv/secure/harbor/tls/harbor.example.com.key

python3 - "$WORK/harbor.yml" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as fh:
    cfg = yaml.safe_load(fh)
assert cfg['hostname'] == 'harbor.example.com'
assert cfg['data_volume'] == '/srv/secure/harbor/data'
assert cfg['log']['local']['location'] == '/srv/secure/harbor/logs'
assert cfg['https']['certificate'].endswith('harbor.example.com.crt')
assert cfg['external_database']['harbor']['host'] == 'postgres.example.com'
assert cfg['external_database']['harbor']['ssl_mode'] == 'require'
assert cfg['external_database']['harbor']['password'] == 'db-secret'
s = cfg['storage_service']['s3']
assert s['regionendpoint'] == 'https://s3.example.com'
assert s['bucket'] == 'harbor'
assert s['forcepathstyle'] is True
assert s['v4auth'] is True
assert s['accesskey'] == 'access-secret'
assert s['secretkey'] == 's3-secret'
assert 'filesystem' not in cfg['storage_service']
assert cfg['jobservice']['job_loggers'] == ['STD_OUTPUT', 'DB']
assert cfg['harbor_admin_password'] == 'admin-secret'
PY

[[ $(stat -c '%a' "$WORK/harbor.yml") == 600 ]]
printf 'Harbor config renderer: PASS\n'
