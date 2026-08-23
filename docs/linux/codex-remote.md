# Linux Codex Remote Host Provisioning

`linux/codex-remote/setup.sh` prepares a Debian or Ubuntu machine for use as an
SSH-backed Codex remote project host. The tool runs on the Linux workstation
where ChatGPT reads `~/.ssh/config`; it converges both the workstation SSH state
and the selected remote account.

## Resulting architecture

```text
Linux workstation
  ~/.ssh/config
    -> Include ~/.ssh/config.d/deployscripts/*.conf
  ~/.ssh/config.d/deployscripts/codex-remote-ALIAS.conf
  ~/.ssh/codex_ALIAS
          |
          | dedicated Ed25519 identity
          v
Debian/Ubuntu remote account
  ~/.ssh/authorized_keys
  login-shell PATH -> codex
  authenticated Codex CLI and app-server
```

ChatGPT discovers concrete aliases from the workstation SSH configuration and
starts the remote Codex app server through the remote account's login shell. The
tool therefore validates the effective OpenSSH configuration, unattended SSH,
the login-shell `PATH`, Codex authentication, and `codex app-server`.

## Prerequisites

The workstation must be Linux and provide:

- Bash;
- OpenSSH client and `ssh-keygen`;
- standard GNU utilities including `awk`, `sed`, `base64`, and `sha256sum`.

The target must:

- run Debian or Ubuntu;
- already run an SSH server;
- permit one initial authentication method: an account password, an existing
  identity, or a key available through the SSH agent;
- allow the selected user to use `sudo` when `curl`, `ca-certificates`, or `git`
  must be installed and the account is not root;
- have outbound HTTPS access when Codex must be installed or authenticated.

The script never accepts or stores an SSH or `sudo` password. OpenSSH and `sudo`
perform their normal terminal prompts.

## Quick start

```bash
./linux/codex-remote/setup.sh \
  --name s3-storage-box-germany \
  --host 203.0.113.10 \
  --user aadmin
```

The first run normally asks for host-key confirmation, initial SSH
authentication, and Codex device-code authentication. A successful run ends
with:

```text
CODEX REMOTE READINESS: PASS
```

Afterward, open ChatGPT **Settings > Connections > SSH**, enable the concrete
alias, and select a project directory on the remote host.

## Initial access with another identity

When the VPS provider installed an existing administrative key, use it only to
bootstrap the dedicated identity:

```bash
./linux/codex-remote/setup.sh \
  --name build-box \
  --host build.example.com \
  --user deploy \
  --bootstrap-identity ~/.ssh/provider_initial_key
```

The bootstrap identity is not written into the managed host configuration. Once
the dedicated key works, later runs do not need this option.

## Managed local files

Defaults for an alias named `build-box` are:

```text
~/.ssh/codex_build_box
~/.ssh/codex_build_box.pub
~/.ssh/config
~/.ssh/config.d/deployscripts/codex-remote-build_box.conf
~/.local/state/deployscripts/backups/codex-remote/
```

The main SSH config receives one marked `Include` at the beginning of the file.
Each host is then owned through a separate marked file. Unrelated SSH
configuration is preserved.

The managed host file records the requested host, user, port, and key path in
comments. After a successful first run, repair and check commands can recover
those values from only the alias:

```bash
./linux/codex-remote/setup.sh --name build-box --check
```

## Remote files changed

The tool manages one key line in:

```text
~/.ssh/authorized_keys
```

Its final comment is:

```text
deployscripts:codex-remote:ALIAS
```

Only the final and temporary rotation markers belonging to that exact alias are
replaced. Every unrelated authorized key is preserved. The remote SSH directory
and file are validated as `0700` and `0600` respectively.

Remote authorized-key backups are stored beneath:

```text
~/.local/state/deployscripts/backups/codex-remote/authorized_keys/
```

## Codex installation and authentication

The default `--codex-install ensure` mode leaves an available Codex CLI alone
and otherwise runs the official Linux installer as the remote user:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Modes are:

```text
ensure   install only when codex is unavailable in the login-shell PATH
update   run the official installer even when codex is already available
skip     require an existing codex command and never install or update it
```

Authentication defaults to `--auth device`. Existing authentication is reused;
otherwise the script starts:

```bash
codex login --device-auth
```

Use `--auth skip` when authentication is intentionally handled separately. A
readiness run with skipped authentication reports that state without claiming
the login is active.

## Idempotent reruns and repair

Every run inspects live state rather than trusting a stored step counter. It:

1. validates or repairs the local public key;
2. renders and validates managed OpenSSH configuration;
3. converges only the marked remote authorized-key line;
4. proves unattended SSH works;
5. inspects the remote platform and required packages;
6. ensures Codex is in the remote login-shell `PATH`;
7. reuses or establishes authentication;
8. validates the CLI and app-server.

If a run is interrupted, rerun the same command. Already-correct phases are
left unchanged and missing phases are completed. A missing `.pub` file is
regenerated from the existing private key. A public key without its private key,
or a mismatched keypair, is refused rather than overwritten.

## Backups

Configuration is backed up immediately before each content-changing write.
Unchanged files do not generate backups. The default is the newest ten backups
per file on both the workstation and remote account.

Override the local root or retention count:

```text
--backup-root PATH
--backup-limit NUMBER
```

The limit may be between 1 and 100. Replacement files are written through a
temporary file and atomic rename.

## Key rotation

```bash
./linux/codex-remote/setup.sh --name build-box --rotate-key
```

Rotation keeps the existing key active while it:

1. creates a temporary Ed25519 identity;
2. installs a temporary marked public key without removing the current key;
3. proves the temporary identity can authenticate directly;
4. backs up and replaces the local keypair;
5. reconnects and replaces the temporary/old markers with the final marker;
6. runs the complete readiness validation.

If new-key verification fails, the current local identity remains unchanged.

## Existing aliases and retargeting

An unmanaged exact `Host ALIAS` declaration is refused by default. Use
`--replace-existing` to place the DeployScripts include first and deliberately
give the managed alias precedence. The original declaration is preserved for
manual inspection rather than destructively rewritten.

Changing the host, remote user, or port of an already managed alias is also
refused by default:

```bash
./linux/codex-remote/setup.sh \
  --name build-box \
  --host replacement.example.com \
  --user deploy \
  --retarget
```

Retargeting does not remove the previously authorized key from the old server.
Use a new alias for a genuinely different machine when independent revocation is
the goal, or remove the old marked key from the retired host after verifying the
replacement.

## Read-only and planning modes

Read-only end-to-end validation:

```bash
./linux/codex-remote/setup.sh --name build-box --check
```

Plan a new or changed setup without intentionally altering local or remote
state:

```bash
./linux/codex-remote/setup.sh \
  --name build-box \
  --host build.example.com \
  --user deploy \
  --dry-run
```

`--non-interactive` disables password, host-confirmation, `sudo`, and device-code
prompts. Initial access must already work, required remote packages must be
installable with passwordless sudo, and Codex must already be authenticated or
authentication must be skipped.

## Complete option reference

```text
--name ALIAS
--host HOST
--user USER
--port PORT
--bootstrap-identity PATH
--key-path PATH
--ssh-config PATH
--codex-install ensure|update|skip
--auth device|skip
--replace-existing
--retarget
--rotate-key
--backup-root PATH
--backup-limit NUMBER
--check
--dry-run
--non-interactive
-h, --help
```

Run `./linux/codex-remote/setup.sh --help` for the authoritative compact option
reference of the checked-out revision.

## Important failure behavior

- Unknown SSH host keys use OpenSSH's normal confirmation and known-hosts rules;
  the tool never silently deletes a changed host key.
- A malformed or mismatched local keypair stops the run before remote mutation.
- A conflicting managed endpoint requires explicit `--retarget`.
- An unmanaged exact alias requires explicit `--replace-existing`.
- Replacement-key activation occurs only after direct authentication succeeds.
- Unsupported remote operating systems are rejected before package or Codex
  installation.
- Codex must be visible in the remote login-shell `PATH`, not merely through an
  interactive shell customization.
- Device authentication failure leaves SSH and the Codex installation intact;
  rerunning resumes at authentication.

