# Debian Secure Storage

## Purpose

`debian/secure-storage/setup.sh` creates and maintains a file-backed LUKS2 encrypted filesystem on Debian. It is intended for hosts where application-local writable data, swap, and optionally container runtime storage should live behind one encrypted mount while the base operating system remains on the normal root filesystem.

The script is designed to be rerun. Existing LUKS volumes are inspected rather than reformatted, existing configuration is validated, and conflicting state causes the run to stop instead of guessing.

## Resulting architecture

A typical installation looks like this:

```text
Debian root filesystem
├── /var/lib/deployscripts/secure-storage/<name>.img
│     └── LUKS2 encrypted container
│          └── /dev/mapper/<name>
│               └── ext4 mounted at <mount>
│                    ├── swapfile           (optional)
│                    ├── docker/            (optional)
│                    └── containerd/        (optional)
│
└── /root/.deployscripts/keys/<name>.key
      └── root-only automatic unlock key
```

The LUKS container has two intended unlock methods:

1. a human recovery passphrase supplied interactively during first creation;
2. a randomly generated root-only machine key used by `/etc/crypttab` for automatic boot-time unlock.

The machine key is deliberately stored on the root filesystem. This design protects data at rest on the encrypted image while allowing unattended reboots. It does **not** protect the LUKS image from an attacker who obtains both the root filesystem (including the auto-unlock key) and the encrypted image. Use a different key-management design if that is part of your threat model.

## Supported platform

The tool currently supports Debian and expects systemd, cryptsetup/LUKS2, and an ext4 filesystem inside the encrypted image.

Run it as root, normally through `sudo`.

## First-time setup

Interactive example:

```bash
sudo ./debian/secure-storage/setup.sh \
  --name harbor-secure \
  --mount /srv/secure \
  --image-size 26G \
  --swap 12G \
  --docker
```

On first creation the script asks for a human recovery passphrase and confirmation. The passphrase is not accepted as a command-line argument, so it is not placed in shell history or intentionally exposed through the process list.

The example above creates:

- `/var/lib/deployscripts/secure-storage/harbor-secure.img` as a 26 GiB file-backed LUKS2 container;
- `/dev/mapper/harbor-secure`;
- an ext4 filesystem mounted at `/srv/secure`;
- `/root/.deployscripts/keys/harbor-secure.key` as the automatic unlock key;
- `/srv/secure/swapfile` as a 12 GiB swapfile;
- `/srv/secure/docker` as Docker Engine's persistent data root;
- `/srv/secure/containerd` as containerd's persistent root.

The script prints the machine-key path again when setup completes.

## Command-line options

### Storage

`--name NAME`
: Logical LUKS mapper name. Default: `secure-storage`.

`--mount PATH`
: Mount location for the decrypted filesystem. Default: `/srv/secure`.

`--image-path PATH`
: Location of the file-backed LUKS image. Default: `/var/lib/deployscripts/secure-storage/<name>.img`.

`--image-size SIZE`
: Size of a newly created image, such as `10G`, `26G`, or `512M`. Required when the image does not already exist. The script refuses a new allocation unless at least 2 GiB would remain available on the filesystem containing the image.

`--key-path PATH`
: Location of the root-only machine unlock key. Default: `/root/.deployscripts/keys/<name>.key`.

### Swap

`--swap SIZE`
: Disable other active/configured swap and create or reuse `<mount>/swapfile` at exactly the requested size. Example: `--swap 12G`.

`--no-swap`
: Leave existing swap configuration unchanged.

`--disable-swap`
: Disable active swap and comment existing swap entries in `/etc/fstab` without creating a replacement.

If no swap option is supplied during an interactive setup, the script asks what to do. In non-interactive or check mode, unspecified swap is left unchanged.

An existing encrypted swapfile is never silently resized. If its size conflicts with `--swap`, the script stops and requires an explicit operator decision.

### Docker

`--docker`
: Install Docker Engine from Docker's official Debian APT repository and place persistent Docker and containerd data beneath the encrypted mount.

The module configures:

```text
Docker data-root:   <mount>/docker
containerd root:    <mount>/containerd
```

Both are handled because Docker's `data-root` setting does not relocate containerd's independent persistent root when Docker uses containerd-backed storage.

The module also creates systemd drop-ins for both `docker.service` and `containerd.service` containing `RequiresMountsFor=<mount>`. The intended failure behavior is therefore fail-closed: if the encrypted mount cannot be established, those services should not start successfully against an unencrypted fallback path.

If existing runtime data is found, it is copied with `rsync -aHAX --numeric-ids` while Docker/containerd are stopped. The script refuses to merge two independently populated source and destination trees. After the services restart successfully using encrypted storage, migrated copies under the standard `/var/lib/docker` and `/var/lib/containerd` paths are removed. A non-standard old source path is left in place with a warning so an operator can review it manually.

The Docker module refuses to silently replace conflicting distribution/container packages such as `docker.io`, `containerd`, or `runc`. Resolve those conflicts deliberately before rerunning `--docker`.

Docker changes host networking/firewall behavior as part of normal Docker Engine operation. Review Docker's networking/firewall model separately on hosts with restrictive firewall policy.

### Operating modes

`--check`
: Read-only validation of an existing setup. It checks the LUKS image, machine key, mapper, mount, `/etc/crypttab`, `/etc/fstab`, requested/existing encrypted swap, and Docker/containerd configuration when present. It does not install packages or modify host state.

`--dry-run`
: Show intended mutations without making host changes. This is useful for reviewing a rerun or optional-module addition.

`--non-interactive`
: Disable optional prompts. First-time LUKS creation still requires an interactive recovery passphrase and will refuse to proceed in this mode rather than accepting a secret through a CLI argument.

`-h`, `--help`
: Print built-in usage.

## Rerunning the script

The script converges toward requested state instead of treating every invocation as a fresh installation.

For example, after creating secure storage without Docker:

```bash
sudo ./debian/secure-storage/setup.sh \
  --name harbor-secure \
  --mount /srv/secure \
  --image-size 26G \
  --swap 12G
```

Docker can be added later:

```bash
sudo ./debian/secure-storage/setup.sh \
  --name harbor-secure \
  --mount /srv/secure \
  --docker \
  --no-swap
```

The existing LUKS image is inspected and reused. It is not reformatted simply because the script was run again.

A dry run can be used first:

```bash
sudo ./debian/secure-storage/setup.sh \
  --name harbor-secure \
  --mount /srv/secure \
  --docker \
  --no-swap \
  --dry-run
```

## Files and host state changed

Depending on selected modules, the tool may create or modify:

```text
/var/lib/deployscripts/secure-storage/<name>.img
/root/.deployscripts/keys/<name>.key
/etc/crypttab
/etc/fstab
/etc/apt/keyrings/docker.asc
/etc/apt/sources.list.d/docker.sources
/etc/docker/daemon.json
/etc/containerd/config.toml
/etc/systemd/system/docker.service.d/secure-storage.conf
/etc/systemd/system/containerd.service.d/secure-storage.conf
<mount>/swapfile
<mount>/docker/
<mount>/containerd/
```

It may also install Debian packages required for cryptsetup, filesystem/swap management, and optionally Docker Engine.

## Configuration backups

Before changing an existing configuration file, the script copies it beneath:

```text
/var/backups/deployscripts/<UTC timestamp>/
```

The original absolute path is preserved beneath that backup directory, making it clear which host file each backup came from.

Backups are intended as an operator convenience, not as a replacement for normal server backups.

## Boot behavior

Automatic boot behavior is configured through standard Debian/systemd mechanisms:

1. `/etc/crypttab` references the file-backed image and root-only machine key;
2. the mapped device becomes `/dev/mapper/<name>`;
3. `/etc/fstab` mounts that mapper at the requested mount path;
4. an encrypted swapfile listed in `/etc/fstab` is activated after its backing filesystem is available;
5. when Docker is enabled, systemd drop-ins require the secure mount before Docker or containerd may start.

A successful live setup is useful validation, but a real reboot is the definitive test of the boot-time dependency chain.

## Reboot validation

After first setup, reboot the server:

```bash
sudo reboot
```

After reconnecting, run the read-only check using the same identity/path arguments:

```bash
sudo ./debian/secure-storage/setup.sh \
  --name harbor-secure \
  --mount /srv/secure \
  --check
```

If custom `--image-path` or `--key-path` values were used, pass those again to `--check`.

A healthy installation ends with:

```text
BOOT READINESS: PASS
```

Useful manual checks include:

```bash
lsblk -f
findmnt /srv/secure
sudo cryptsetup status harbor-secure
cat /proc/swaps
sudo systemctl status systemd-cryptsetup@harbor\x2dsecure.service
sudo docker info --format '{{.DockerRootDir}}'
sudo containerd config dump | grep '^root'
```

The exact escaped systemd cryptsetup unit name depends on the mapper name.

## Recovery with the human passphrase

The recovery passphrase occupies a LUKS key slot independently of the generated machine key. If the auto-unlock key is lost but the encrypted image survives, the image can be opened manually with the human passphrase.

Example:

```bash
sudo cryptsetup open \
  /var/lib/deployscripts/secure-storage/harbor-secure.img \
  harbor-secure
```

`cryptsetup` prompts for a valid LUKS passphrase.

Then mount the filesystem:

```bash
sudo mkdir -p /srv/secure
sudo mount /dev/mapper/harbor-secure /srv/secure
```

If a replacement automatic key is needed, rerun the setup script with the existing image and key path. When it discovers a missing machine key, it asks for the recovery passphrase and enrolls a new random machine key.

## Inspecting LUKS key slots

To inspect the LUKS metadata without exposing key material:

```bash
sudo cryptsetup luksDump \
  /var/lib/deployscripts/secure-storage/harbor-secure.img
```

Never print or commit the contents of the generated machine key.

## Failure behavior

The script intentionally stops instead of making assumptions when it encounters conditions such as:

- an existing image path that is not a regular file;
- a machine key that no longer unlocks the image;
- an existing mapper or mount that points somewhere unexpected;
- a non-ext4 filesystem in the decrypted mapper;
- conflicting `/etc/crypttab` or `/etc/fstab` entries;
- an existing swapfile with a different requested size;
- both old and new Docker/containerd data locations already containing data;
- invalid existing Docker JSON or containerd configuration;
- conflicting Docker packages from another packaging source.

Resolve the conflict deliberately and rerun the same command.

## Security model

This tool is meant to provide encrypted-at-rest application storage with unattended boot on a server whose root filesystem contains the automatic unlock secret.

The important boundary is:

```text
normal root filesystem
  ├── operating system
  ├── provisioning configuration
  └── automatic unlock key

LUKS encrypted image
  ├── application-local writable data
  ├── swap
  ├── Docker persistent storage
  └── containerd persistent storage
```

It is appropriate when the accepted policy allows the unlock secret to live on the server but requires designated writable application/swap data to be encrypted at rest. It is not equivalent to an operator-entered passphrase at every boot or to external hardware/network key management.

## Removal

Destructive teardown is intentionally not automated by this tool. Removing an encrypted installation can destroy application data and should be performed as an explicit operator procedure after backups and dependencies are understood.
