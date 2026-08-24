#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=debian/k3s/lib/common.sh
source "$ROOT/debian/k3s/lib/common.sh"
# shellcheck source=debian/k3s/lib/config.sh
source "$ROOT/debian/k3s/lib/config.sh"

MODE=init-server
NODE_NAME=prod-k3s-01
NODE_IP=10.250.0.11
NODE_EXTERNAL_IP=203.0.113.11
API_ENDPOINT=https://k3s-prod-api.example.com:6443
DATASTORE=embedded-etcd
FLANNEL_BACKEND=vxlan
FLANNEL_IFACE=wg0
SECRETS_ENCRYPTION=1
SNAPSHOT_SCHEDULE='0 */12 * * *'
SNAPSHOT_RETENTION=5
TLS_SANS=(10.250.0.100 api-alt.example.com)
DISABLED_COMPONENTS=(servicelb)
NODE_LABELS=(sayou.io/environment=production)
NODE_TAINTS=(sayou.io/control-plane=true:NoSchedule)
AGENT_TOKEN_SOURCE=/root/agent-token

render_cluster_config "$WORK/cluster.yaml"
render_node_config "$WORK/node.yaml"
render_role_config "$WORK/role.yaml"

grep -Fq "  - 'k3s-prod-api.example.com'" "$WORK/cluster.yaml"
grep -Fq "flannel-backend: 'vxlan'" "$WORK/cluster.yaml"
grep -Fq 'secrets-encryption: true' "$WORK/cluster.yaml"
grep -Fq "etcd-snapshot-schedule-cron: '0 */12 * * *'" "$WORK/cluster.yaml"
grep -Fq "  - 'servicelb'" "$WORK/cluster.yaml"
grep -Fq "node-name: 'prod-k3s-01'" "$WORK/node.yaml"
grep -Fq "node-external-ip: '203.0.113.11'" "$WORK/node.yaml"
grep -Fq "flannel-iface: 'wg0'" "$WORK/node.yaml"
grep -Fq "cluster-init: true" "$WORK/role.yaml"
grep -Fq "token-file: '$K3S_MANAGED_TOKEN_FILE'" "$WORK/role.yaml"

MODE=join-server
render_role_config "$WORK/join-server.yaml"
grep -Fq "server: 'https://k3s-prod-api.example.com:6443'" "$WORK/join-server.yaml"
if grep -Fq 'cluster-init:' "$WORK/join-server.yaml"; then
  printf 'join-server role unexpectedly contains cluster-init\n' >&2
  exit 1
fi

MODE=join-agent
render_role_config "$WORK/join-agent.yaml"
grep -Fq "server: 'https://k3s-prod-api.example.com:6443'" "$WORK/join-agent.yaml"
grep -Fq "token-file: '$K3S_MANAGED_AGENT_TOKEN_FILE'" "$WORK/join-agent.yaml"

printf 'K3s config renderer: PASS\n'
