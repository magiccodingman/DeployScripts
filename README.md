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

## Repository conventions

See [`docs/conventions.md`](docs/conventions.md) for layout, naming, idempotency, safety, and documentation rules.
