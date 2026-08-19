# Debian K3s

## Purpose

`debian/k3s/setup.sh` creates or converges one Debian K3s node in one of three
explicit roles:

- `init-server`: create the first server of a new SQLite or embedded-etcd cluster;
- `join-server`: add a control-plane/embedded-etcd server through a stable API endpoint;
- `join-agent`: add a worker-only node through a stable API endpoint.

The tool owns K3s host bootstrap and node registration. It does not provision
HAProxy, create a Rancher cluster entry, deploy workloads, create Kubernetes
image-pull Secrets, modify the host firewall, or integrate K3s storage with the
separate DeployScripts secure-storage capability.

## Resulting architecture

The tool installs the official K3s systemd service and writes separate native
K3s configuration drop-ins:

```text
/etc/rancher/k3s/config.yaml.d/
  10-deployscripts-cluster.yaml  # server-only settings shared by every server
  20-deployscripts-node.yaml     # node name, addresses, labels, and taints
  30-deployscripts-role.yaml     # initialize or join behavior and token file
```

Cluster tokens are copied into root-only files below `/etc/rancher/k3s` and are
never stored in DeployScripts state or printed. The non-secret state file at
`/var/lib/deployscripts/k3s/state.env` allows `--check` and safe no-argument
reruns after the first installation.

K3s uses its standard `/var/lib/rancher/k3s` data directory. No Docker daemon
is installed; K3s uses its bundled containerd runtime.

## Supported platform and prerequisites

- Debian 13 on x86_64 is exercised by CI.
- Run the tool as root.
- Assign every cluster node a unique name.
- Prefer an SSD for embedded etcd.
- Provide a private datacenter or WireGuard address as `--node-ip` whenever possible.
- Configure DNS and HAProxy before joining nodes through the stable endpoint.
- Keep time synchronization healthy on every node.

The script installs its small host dependency set, loads the `overlay` and
`br_netfilter` modules, and writes the required forwarding sysctls. It reports
active swap but deliberately does not change swap configuration.

## First on-premises server

Using embedded etcd on a single-node rehearsal cluster exercises the same
datastore initialization used by a future three-server production cluster:

```bash
sudo ./debian/k3s/setup.sh \
  --mode init-server \
  --node-name onprem-k3s-01 \
  --node-ip 10.77.77.21 \
  --api-endpoint https://k3s-onprem.example.com:6443 \
  --datastore embedded-etcd \
  --flannel-backend vxlan
```

If `--token-file` is omitted for `init-server`, the script generates a strong
root-only server token at `/etc/rancher/k3s/deployscripts-server-token`.

A deliberately permanent single-server cluster can instead use
`--datastore sqlite`. Adding server nodes later requires an explicit SQLite to
embedded-etcd conversion outside this tool; the setup script never performs
that conversion implicitly.

## Production initialization behind HAProxy

Use a stable DNS name for the Kubernetes API and K3s registration endpoint.
HAProxy should forward TCP without terminating K3s TLS:

```haproxy
frontend k3s_api
    bind *:6443
    mode tcp
    option tcplog
    default_backend k3s_servers

backend k3s_servers
    mode tcp
    option tcp-check
    balance roundrobin
    server prod-k3s-01 10.250.0.11:6443 check
```

Initialize the first server after the first HAProxy backend is prepared:

```bash
sudo ./debian/k3s/setup.sh \
  --mode init-server \
  --node-name prod-k3s-01 \
  --node-ip 10.250.0.11 \
  --node-external-ip 203.0.113.11 \
  --api-endpoint https://k3s-prod-api.example.com:6443 \
  --datastore embedded-etcd \
  --flannel-backend vxlan \
  --flannel-iface wg0 \
  --token-file /root/k3s-production.token
```

The endpoint hostname is automatically added to the Kubernetes API TLS SANs.
Additional names or addresses may be supplied through repeatable `--tls-san`
arguments.

## Joining additional servers

Copy the token to the new host through a secure channel as a root-owned mode
`0600` file, then join through HAProxy:

```bash
sudo ./debian/k3s/setup.sh \
  --mode join-server \
  --node-name prod-k3s-02 \
  --node-ip 10.250.0.12 \
  --node-external-ip 203.0.113.12 \
  --api-endpoint https://k3s-prod-api.example.com:6443 \
  --flannel-backend vxlan \
  --flannel-iface wg0 \
  --token-file /root/k3s-production.token
```

All server-mode invocations must use matching Flannel, Secret-encryption,
disabled-component, and network settings. K3s independently rejects critical
configuration mismatches. Add a server to the HAProxy backend only after the
node is healthy. An embedded-etcd HA cluster should contain an odd number of
servers, normally three.

## Joining worker agents

An agent does not receive server-only cluster configuration:

```bash
sudo ./debian/k3s/setup.sh \
  --mode join-agent \
  --node-name prod-worker-01 \
  --node-ip 10.250.0.21 \
  --api-endpoint https://k3s-prod-api.example.com:6443 \
  --agent-token-file /root/k3s-production-agent.token
```

`--token-file` is also accepted for an agent when the cluster intentionally
uses the same token. Supplying a distinct agent token limits the token's use to
joining agents.

When the first server is configured with a distinct `--agent-token-file`, pass
the same protected agent-token file to every later `join-server` invocation so
the server configurations remain consistent. The generated agent token on a
server that uses K3s's default token behavior is available at
`/var/lib/rancher/k3s/server/agent-token`.

## Networking and firewall

HAProxy supplies a stable API and initial registration address. It does not
proxy all later node-to-node traffic. K3s agents learn the individual server
addresses after registration, and etcd, kubelet, and CNI traffic remain direct.

Recommended production transport, in preference order:

1. provider private network;
2. host-to-host WireGuard mesh with private node addresses;
3. public node addresses with `wireguard-native` Flannel and exact-IP firewall allowlists.

When a WireGuard mesh provides the private transport, use the WireGuard address
as `--node-ip`, `--flannel-iface wg0`, and either VXLAN or WireGuard-native
Flannel. The outer WireGuard tunnel protects VXLAN in that arrangement.

Required cluster traffic is:

| Protocol/port | Source | Destination | Purpose |
| --- | --- | --- | --- |
| TCP 6443 | HAProxy and cluster nodes | servers | supervisor and Kubernetes API |
| TCP 2379-2380 | servers | servers | embedded-etcd peer/client traffic |
| TCP 10250 | cluster nodes | cluster nodes | kubelet API and metrics |
| UDP 8472 | cluster nodes | cluster nodes | Flannel VXLAN only |
| UDP 51820 | cluster nodes | cluster nodes | Flannel WireGuard IPv4 only |

Never expose UDP 8472 broadly to the Internet. The script refuses VXLAN when
`--node-ip` is globally routable unless `--allow-public-vxlan` is explicitly
provided. That escape hatch does not alter the firewall and should not replace
a private or encrypted transport.

Public application traffic is separate from the K3s API frontend. HAProxy can
forward ports 80 and 443 to ingress-capable nodes while forwarding port 6443 to
server nodes. If cert-manager owns application certificates inside Kubernetes,
keep application TLS termination inside the cluster.

## Harbor

For ordinary authenticated application pulls, prefer namespace-scoped
Kubernetes `imagePullSecrets` managed by the deployment pipeline. Use
`--registry-config PATH` when a node needs a custom CA, registry mirror, or
node-level registry configuration. The supplied file is installed as
`/etc/rancher/k3s/registries.yaml`, root-owned mode `0600`, before K3s starts.

Registry configuration and credentials are never accepted inline as command
arguments. Changes to `registries.yaml` take effect when the script restarts
the applicable K3s service.

## Rancher

Rancher is a management plane, not the K3s registration endpoint. Create and
validate the K3s cluster first, then import it into Rancher and apply Rancher's
generated registration manifest once. The cluster remains independently
functional when Rancher is unavailable.

## Options

| Option | Description |
| --- | --- |
| `--mode MODE` | `init-server`, `join-server`, or `join-agent` |
| `--node-name NAME` | Unique Kubernetes node name |
| `--node-ip IP` | Address K3s advertises for node traffic |
| `--node-external-ip IP` | Optional externally advertised node address |
| `--api-endpoint URL` | Stable HTTPS endpoint; port defaults to 6443 |
| `--token-file PATH` | Root-owned server or general join-token file |
| `--agent-token-file PATH` | Optional distinct agent-token file |
| `--datastore TYPE` | `sqlite` or `embedded-etcd` for `init-server` |
| `--flannel-backend TYPE` | `vxlan` or `wireguard-native` for server modes |
| `--flannel-iface IFACE` | Interface used for Flannel traffic |
| `--tls-san VALUE` | Additional API certificate SAN; repeatable |
| `--node-label KEY=VALUE` | Initial node label; repeatable |
| `--node-taint TAINT` | Initial node taint; repeatable |
| `--disable COMPONENT` | Disable a packaged K3s component; repeatable |
| `--secrets-encryption` | Enable Kubernetes Secret encryption; default |
| `--no-secrets-encryption` | Explicitly disable Secret encryption |
| `--snapshot-schedule CRON` | Embedded-etcd snapshot schedule |
| `--snapshot-retention N` | Local embedded-etcd snapshot retention |
| `--version VERSION` | Exact version for a new installation |
| `--channel CHANNEL` | Release channel for a new installation; default `stable` |
| `--registry-config PATH` | Root-only source for `registries.yaml` |
| `--allow-public-vxlan` | Override the public-node-IP VXLAN refusal |
| `--check` | Validate without changing the host |
| `--dry-run` | Print intended mutations |
| `--non-interactive` | Refuse prompts |

`--version` and `--channel` are mutually exclusive. An existing K3s installation
is never automatically upgraded. If `--version` conflicts with the installed
version, the script stops and leaves upgrades to a deliberate maintenance flow.

## Idempotency and reruns

After a successful first run, these are sufficient:

```bash
sudo ./debian/k3s/setup.sh --check
sudo ./debian/k3s/setup.sh --non-interactive
```

The saved state contains no tokens. Reruns back up managed files immediately
before changing them and preserve the installed K3s version. The tool refuses
role, node-name, node-IP, datastore, and Flannel-backend conflicts instead of
silently changing node identity or cluster architecture.

## Files and services changed

- `/etc/rancher/k3s/config.yaml.d/10-deployscripts-cluster.yaml` on servers;
- `/etc/rancher/k3s/config.yaml.d/20-deployscripts-node.yaml`;
- `/etc/rancher/k3s/config.yaml.d/30-deployscripts-role.yaml`;
- `/etc/rancher/k3s/deployscripts-server-token`;
- `/etc/rancher/k3s/deployscripts-agent-token` when configured;
- `/etc/rancher/k3s/registries.yaml` when supplied;
- `/etc/sysctl.d/90-deployscripts-k3s.conf`;
- `/var/lib/deployscripts/k3s/state.env`;
- standard K3s files under `/var/lib/rancher/k3s`;
- `k3s.service` for servers or `k3s-agent.service` for agents.

Backups are written below a timestamped `/var/backups/deployscripts` directory.

## Validation

The final setup validation and `--check` verify:

- K3s binary and systemd service state;
- root ownership and modes for managed configuration and tokens;
- IPv4 forwarding;
- local Kubernetes node readiness on servers;
- embedded-etcd snapshot subsystem availability;
- kubelet/containerd runtime files on agents.

Useful independent commands include:

```bash
sudo systemctl status k3s --no-pager
sudo journalctl -u k3s -n 200 --no-pager
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
sudo k3s etcd-snapshot ls
```

The admin kubeconfig at `/etc/rancher/k3s/k3s.yaml` is root-only and grants full
cluster administration. Do not use it as a GitLab deployment credential;
create a restricted service account and kubeconfig for automation.

## Recovery and important failure modes

- If the stable API endpoint is unreachable, correct DNS/HAProxy/firewall state
  and rerun the same command.
- If a joining node reuses an old node name without its original
  `/etc/rancher/node/password`, delete the old Kubernetes Node so K3s can remove
  the corresponding node-password Secret before retrying.
- If critical server settings differ, correct the invocation to match the first
  server. Do not bypass K3s's critical-configuration mismatch protection.
- Recover embedded etcd using a tested snapshot and the official K3s
  cluster-reset restore procedure. Cluster reset is intentionally not exposed by
  this setup script.
- Use the official K3s uninstall scripts only as an explicit destructive action.
  This tool never invokes them.
- Backups under `/var/backups/deployscripts` cover configuration changes, not the
  Kubernetes datastore. Preserve and test embedded-etcd snapshots separately.

## CI coverage

Cheap shell syntax and ShellCheck run globally. The path-scoped Debian K3s
workflow also renders every role configuration and boots a disposable Debian 13
VM to exercise clean embedded-etcd installation, readiness, `--check`, an
idempotent rerun, a full power-off/cold boot, and final validation.
