# DeployScripts

Reusable deployment and host-provisioning tools.

This repository is organized by platform and capability. Top-level documentation is intentionally an index; each tool owns its detailed usage and recovery documentation under `docs/`.

## Debian

### Secure Storage

Creates and maintains a file-backed LUKS2 encrypted filesystem with:

- automatic boot-time unlock using a root-only machine key;
- a separate human recovery passphrase;
- automatic mount configuration;
- optional encrypted swap inside the mounted filesystem;
- optional Docker Engine installation with Docker and containerd persistent data relocated into encrypted storage;
- `--check` and `--dry-run` modes;
- safe reruns that converge existing installations instead of reformatting them.

Quick start:

```bash
git clone https://github.com/magiccodingman/DeployScripts.git
cd DeployScripts

sudo ./debian/secure-storage/setup.sh \
  --name harbor-secure \
  --mount /srv/secure \
  --image-size 26G \
  --swap 12G \
  --docker
```

Detailed documentation: [`docs/debian/secure-storage.md`](docs/debian/secure-storage.md)

### Harbor

Installs or converges Harbor as a rebuildable Debian service with:

- external PostgreSQL instead of Harbor's bundled database;
- S3-compatible registry artifact storage with no filesystem blob fallback;
- local Harbor state, logs, configuration, credentials, and TLS material beneath an encrypted application mount by default;
- optional Let's Encrypt HTTPS while Harbor's own nginx terminates TLS;
- automatic certificate renewal;
- optional Trivy;
- PostgreSQL/S3 preflight checks, read-only `--check`, and safe idempotent reruns.

Quick start:

```bash
sudo ./debian/harbor/setup.sh \
  --hostname harbor.example.com \
  --db-host postgres.example.com \
  --s3-endpoint https://s3.example.com \
  --s3-bucket harbor \
  --letsencrypt
```

Database/S3/admin secrets are prompted interactively or supplied through documented environment variables/root-only secret files rather than command-line arguments.

Detailed documentation: [`docs/debian/harbor.md`](docs/debian/harbor.md)

## Repository conventions

See [`docs/conventions.md`](docs/conventions.md) for layout, naming, idempotency, safety, and documentation rules.
