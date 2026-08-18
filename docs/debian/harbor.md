# Debian Harbor

`debian/harbor/setup.sh` installs or converges a single-host Harbor deployment that uses external PostgreSQL for Harbor application state and S3-compatible object storage for registry artifacts.

The tool is designed for rebuildable Harbor hosts. Local Harbor state, generated configuration, logs, TLS material, and persisted credentials default beneath `/srv/secure/harbor`, so they can live on the encrypted filesystem created by the Secure Storage tool. Docker and containerd storage are intentionally managed separately by `debian/secure-storage/setup.sh --docker`.

## Resulting architecture

```text
clients
  |
  | HTTPS (optional, recommended)
  v
Harbor nginx / Docker Compose host
  |-- Harbor application containers
  |-- local Redis / transient working state
  |
  +--> external PostgreSQL
  |
  +--> S3-compatible object storage (registry blobs)
```

The generated registry configuration uses the S3 driver only. The tool does not configure a local filesystem registry-storage fallback.

## Supported platform and Harbor version

The tool currently targets Debian and defaults to Harbor `2.15.2`.

Override the version with `--version VERSION` when deliberately deploying another compatible release. If an existing deployment was prepared with another Harbor version, the tool refuses to silently perform an in-place upgrade. Harbor upgrades should be deliberate because upstream migrations and compatibility requirements may change between releases.

## Prerequisites

Before installing Harbor:

- Docker Engine and Docker Compose v2 must be installed and running.
- For encrypted local Harbor/Docker storage, run the Secure Storage tool with `--docker` first.
- The external PostgreSQL database and login must already exist and be reachable from the Harbor host.
- The S3-compatible bucket must already exist and the supplied credentials must have the access Harbor requires.
- For Let's Encrypt HTTP-01, public DNS for the Harbor hostname must resolve to this host and inbound TCP 80/443 must be reachable.

The Harbor script verifies PostgreSQL and S3 before starting Harbor.

## Quick start

```bash
sudo ./debian/harbor/setup.sh \
  --hostname harbor.example.com \
  --db-host postgres.example.com \
  --s3-endpoint https://s3.example.com \
  --s3-bucket harbor \
  --letsencrypt
```

The PostgreSQL password, S3 access key, S3 secret key, and initial Harbor admin password are prompted interactively when they are not already available.

A DNS name is preferred for `--db-host` so infrastructure can move without rewriting Harbor configuration as long as the DNS name remains stable.

## Secrets

Secrets are deliberately **not accepted as command-line arguments** because command-line values can leak through shell history and process inspection.

The tool understands these environment variables:

```text
HARBOR_DB_PASSWORD
HARBOR_S3_ACCESS_KEY
HARBOR_S3_SECRET_KEY
HARBOR_ADMIN_PASSWORD
```

Example non-interactive execution:

```bash
sudo env \
  HARBOR_DB_PASSWORD='...' \
  HARBOR_S3_ACCESS_KEY='...' \
  HARBOR_S3_SECRET_KEY='...' \
  HARBOR_ADMIN_PASSWORD='...' \
  ./debian/harbor/setup.sh \
    --hostname harbor.example.com \
    --db-host postgres.example.com \
    --s3-endpoint https://s3.example.com \
    --s3-bucket harbor \
    --letsencrypt \
    --acme-email admin@example.com \
    --non-interactive
```

After the first successful setup, the secrets are stored by default at:

```text
/srv/secure/harbor/secrets.env
```

The file is root-owned with mode `0600`. Use `--secret-file PATH` to use another root-owned `0600` file. Environment variables override values loaded from the file.

The generated `harbor.yml` necessarily contains credentials required by Harbor and is therefore also written mode `0600` beneath the encrypted Harbor root.

## PostgreSQL options

```text
--db-host HOST       required; DNS hostname preferred
--db-port PORT       default: 5432
--db-name NAME       default: harbor
--db-user USER       default: harbor
--db-ssl-mode MODE   default: require
```

Before Harbor preparation, the script performs an authenticated `SELECT 1` against the requested database using the configured SSL mode.

The generated Harbor configuration uses `external_database.harbor`. Validation explicitly rejects generated Compose configurations containing a bundled `postgresql` or `database` service.

## S3 options

```text
--s3-endpoint URL          required; HTTPS is assumed when no scheme is supplied
--s3-bucket NAME           required
--s3-region REGION         default: us-east-1
--s3-root-prefix PREFIX    optional object-key prefix inside the bucket
--s3-virtual-hosted-style  use virtual-hosted addressing instead of forced path style
--s3-skip-verify           disable endpoint TLS verification; not recommended
--disable-s3-redirect      proxy registry downloads through Harbor instead of S3 redirects
```

For custom S3-compatible endpoints, path-style addressing is enabled by default.

During normal setup the script verifies bucket access by creating and deleting a tiny `.deployscripts-probe/...` object. `--check` performs a read-only bucket check instead.

The generated Harbor registry storage configuration uses S3 Signature V4 and contains no filesystem blob-storage backend.

## Local storage boundary

Default Harbor root:

```text
/srv/secure/harbor
```

The script checks the filesystem backing the Harbor root. By default it refuses to place Harbor's writable local state on the OS root filesystem. This protects deployments that intend Harbor/Docker runtime state to live inside a dedicated encrypted filesystem.

To intentionally permit root-backed storage:

```text
--allow-root-filesystem
```

Use that override only when the lack of a separate encrypted/application mount is intentional.

Within the Harbor root, the tool manages areas including:

```text
data/          Harbor local data, secrets, Redis/transient component state
logs/          Harbor local container logs
installer/     versioned Harbor installer, generated Compose/config files
downloads/     downloaded installer archive
tls/           stable certificate/key copies used directly by Harbor
letsencrypt/   optional Certbot state
secrets.env    root-only deployment credentials
deployscripts-state.env  non-secret optional-mode state
```

Registry artifact blobs remain in the configured S3 bucket rather than `data/` filesystem storage.

## HTTPS modes

Production Harbor should normally use HTTPS. Harbor's own nginx remains the TLS endpoint in all TLS modes; the deployment tool does not place another reverse proxy in front of Harbor.

### Let's Encrypt

```bash
--letsencrypt
--acme-email admin@example.com
```

If `--acme-email` is omitted during an interactive run, it is prompted.

The initial certificate is obtained with Certbot's standalone HTTP-01 challenge. Certbot state is kept beneath the Harbor root. Because Certbot's `live/` files are symlinks, the tool copies the current certificate and private key into stable files under `tls/` and points Harbor at those files.

A systemd service/timer is installed for renewal:

```text
/usr/local/sbin/deployscripts-harbor-cert-renew
/etc/systemd/system/deployscripts-harbor-cert-renew.service
/etc/systemd/system/deployscripts-harbor-cert-renew.timer
```

The timer runs twice daily with randomized delay and is persistent across downtime. Renewal temporarily stops the Harbor Compose stack so Certbot can bind HTTP port 80, stages renewed TLS material, reruns Harbor `prepare`, and starts the stack again. This means a certificate renewal that actually occurs can cause a short Harbor interruption.

### Existing certificate

```bash
--tls-cert /path/to/fullchain.pem \
--tls-key /path/to/privkey.pem
```

The certificate and key are copied into the encrypted Harbor `tls/` directory. Future reruns can reuse those staged files.

### HTTP only

```text
--http-only
```

This is explicit because Harbor production deployments should normally use HTTPS.

## Trivy

Trivy is optional and disabled by default for a new deployment.

```text
--with-trivy
--without-trivy
```

The chosen state is recorded so an ordinary rerun does not unexpectedly change whether the scanner is installed.

## Idempotent reruns

Running the same command again is expected and is the supported rebuild/convergence workflow.

The tool:

- reuses an existing matching Harbor installer version;
- reloads the root-only secret file;
- revalidates PostgreSQL and S3;
- regenerates `harbor.yml` from Harbor's version-specific official template;
- reruns Harbor's official `prepare` operation;
- converges the Compose stack with `docker compose up -d`;
- preserves the previously selected TLS/Trivy mode when those optional flags are omitted.

It does **not** call Harbor's stock `install.sh`, because upstream `install.sh` performs a `docker compose down -v` before starting the stack. DeployScripts instead prepares and converges the existing stack without deliberately deleting Docker volumes.

## Validation

A normal successful run ends with Harbor validation.

Read-only validation can be run later with the same connection arguments:

```bash
sudo ./debian/harbor/setup.sh \
  --hostname harbor.example.com \
  --db-host postgres.example.com \
  --s3-endpoint https://s3.example.com \
  --s3-bucket harbor \
  --check
```

Validation checks include:

- external PostgreSQL connectivity;
- read-only S3 bucket access;
- Harbor configuration and generated Compose validity;
- absence of a bundled local PostgreSQL service;
- S3 registry storage rather than filesystem storage;
- root-only secret-file permissions;
- TLS material when enabled;
- Let's Encrypt renewal timer when managed by this tool;
- running state of all generated Harbor Compose services.

A fully healthy deployment ends with:

```text
HARBOR READINESS: PASS
```

## Dry run

```text
--dry-run
```

Dry-run mode prints the intended host-level operations and does not intentionally create the Harbor deployment. It uses placeholder secret values for configuration planning instead of prompting.

## Rebuilding a lost Harbor host

A typical rebuild is:

1. provision Debian;
2. recreate/mount the encrypted Secure Storage location and Docker data root;
3. restore or provide the Harbor connection credentials;
4. run this Harbor tool with the same hostname, external PostgreSQL, and S3 configuration;
5. validate Harbor.

PostgreSQL and S3 remain the critical external state stores. Local Harbor state such as Redis queues, caches, scanner databases, and generated runtime configuration may be recreated during a host rebuild.

Keep the Harbor deployment credentials and any externally managed TLS recovery material available according to your backup policy even though they are small compared with the registry data itself.

## Important failure behavior

- PostgreSQL validation failure stops setup before Harbor is converged.
- S3 validation failure stops setup before Harbor is converged. No local registry-blob fallback is configured.
- Ambiguous Harbor version changes are refused rather than treated as an automatic upgrade.
- If Let's Encrypt issuance/renewal needs port 80, Harbor may be temporarily stopped while Certbot performs the HTTP-01 challenge.
- If certificate issuance fails after an existing Harbor stack was stopped, inspect/fix ACME reachability and rerun the tool.

## Complete option reference

Run:

```bash
./debian/harbor/setup.sh --help
```

The built-in help is the authoritative compact flag reference for the installed revision of the tool.
