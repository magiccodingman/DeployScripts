#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export K3S_CONFIG_DIR="$WORK/etc/rancher/k3s"
export K3S_STATE_DIR="$WORK/var/lib/deployscripts/k3s"
# shellcheck source=debian/k3s/setup.sh
source "$ROOT/debian/k3s/setup.sh"

MODE=init-server
NODE_NAME=test-k3s-01
NODE_IP=10.10.10.11
NODE_EXTERNAL_IP=203.0.113.11
API_ENDPOINT=https://k3s-api.example.com:6443
DATASTORE=embedded-etcd
FLANNEL_BACKEND=vxlan
FLANNEL_IFACE=wg0
SECRETS_ENCRYPTION=1
SNAPSHOT_SCHEDULE='0 */12 * * *'
SNAPSHOT_RETENTION=7
TLS_SANS=(10.10.10.100 api-alt.example.com)
DISABLED_COMPONENTS=(servicelb traefik)
NODE_LABELS=(sayou.io/environment=test)
NODE_TAINTS=(sayou.io/control-plane=true:NoSchedule)
DRY_RUN=0

save_state
[[ $(stat -c '%a' "$K3S_STATE_FILE") == 644 ]]
if grep -Fq 'Token' "$K3S_STATE_FILE"; then
  printf 'Non-secret state unexpectedly contains token material.\n' >&2
  exit 1
fi

MODE=""
NODE_NAME=""
NODE_IP=""
NODE_EXTERNAL_IP=""
API_ENDPOINT=""
DATASTORE=""
FLANNEL_BACKEND=""
FLANNEL_IFACE=""
SECRETS_ENCRYPTION=-1
SNAPSHOT_SCHEDULE=""
SNAPSHOT_RETENTION=""
TLS_SANS=()
DISABLED_COMPONENTS=()
NODE_LABELS=()
NODE_TAINTS=()
load_saved_state

[[ $MODE == init-server ]]
[[ $NODE_NAME == test-k3s-01 ]]
[[ $NODE_IP == 10.10.10.11 ]]
[[ $DATASTORE == embedded-etcd ]]
[[ $FLANNEL_BACKEND == vxlan ]]
[[ $SNAPSHOT_RETENTION == 7 ]]
[[ ${TLS_SANS[*]} == '10.10.10.100 api-alt.example.com' ]]
[[ ${DISABLED_COMPONENTS[*]} == 'servicelb traefik' ]]

printf 'test-server-token\n' > "$WORK/source-token"
chmod 0600 "$WORK/source-token"
copy_token_file "$WORK/source-token" "$K3S_MANAGED_TOKEN_FILE" "Test token"
[[ $(stat -c '%a' "$K3S_MANAGED_TOKEN_FILE") == 600 ]]
cmp -s "$WORK/source-token" "$K3S_MANAGED_TOKEN_FILE"

install -d -m 0755 "$K3S_DROPIN_DIR"
cat > "$WORK/unmanaged-safe.yaml" <<'EOF'
debug: false
EOF
cp "$WORK/unmanaged-safe.yaml" "$K3S_DROPIN_DIR/90-operator.yaml"
ensure_no_unmanaged_config_conflicts

cat > "$K3S_DROPIN_DIR/90-operator.yaml" <<'EOF'
node-ip: 10.10.10.99
EOF
if (ensure_no_unmanaged_config_conflicts >/dev/null 2>&1); then
  printf 'Overlapping unmanaged config was not rejected.\n' >&2
  exit 1
fi

printf 'K3s state and secret handling: PASS\n'
