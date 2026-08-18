# Repository Conventions

## Purpose

`DeployScripts` is a collection of reusable deployment and host-provisioning tools. Scripts should be safe to rerun, inspect the current machine before changing it, and fail loudly when an existing state is ambiguous.

## Layout

Tools are grouped by platform and capability:

```text
debian/
  <capability>/
    setup.sh
    lib/
docs/
  debian/
    <capability>.md
tests/
  <capability>/
.github/workflows/
```

A capability may contain additional files when they are required at runtime. Code should remain local to the capability until a second tool genuinely needs the same implementation; only then should common logic be promoted to a shared library.

## Script rules

Provisioning entrypoints should:

1. use Bash strict mode (`set -Eeuo pipefail`);
2. require root when changing host state;
3. inspect before mutating;
4. never reformat or overwrite an existing resource merely because the script was rerun;
5. make the smallest change needed to reach the requested state;
6. back up configuration files immediately before modifying them;
7. validate each important mutation;
8. provide `--check` when practical;
9. provide `--dry-run` when practical;
10. never accept secrets as command-line arguments when doing so would expose them through shell history or process listings.

If an existing configuration conflicts with the requested configuration, stop and explain the conflict instead of guessing.

## Testing and CI rules

CI is intentionally layered so the repository can grow without every change running every integration suite.

### Global shell quality

Cheap checks such as Bash syntax, shared regression assertions, and ShellCheck may run for any changed shell script. These checks should stay fast enough to run broadly.

### Tool-owned integration tests

Each substantial capability should own its integration tests under `tests/<capability>/`. Expensive workflows must use GitHub Actions path filters so they run only when that capability, its tests, or shared CI infrastructure relevant to it changes.

For example, a future change under `debian/wireguard/` should not run the secure-storage integration suite unless it also changes shared test infrastructure used by secure-storage.

### Reusable workflows

Common runner/bootstrap behavior should live in reusable workflows under `.github/workflows/` and be called by small capability-specific workflows. This keeps platform setup consistent without coupling unrelated integration suites.

### Provisioning behavior to test

When practical, provisioning integration tests should cover:

1. a clean first installation;
2. validation of the resulting state;
3. a second non-interactive run proving idempotency;
4. important optional modules independently or as explicit scenarios;
5. persistence across a real reboot when the tool manages boot-time storage, mounts, services, networking, swap, or similar system state;
6. a final read-only validation after reboot.

Tests that exercise low-level host state such as device mapper, LUKS, swap, mounts, or systemd boot ordering should use an isolated VM rather than relying on container namespaces when host state could leak into the test.

## Documentation rules

The repository `README.md` is an index, not the full manual. Each substantial tool should have detailed documentation under `docs/<platform>/`.

Documentation should include:

- purpose and resulting architecture;
- prerequisites and supported platforms;
- interactive and non-interactive examples;
- every supported flag;
- idempotent/rerun behavior;
- files and services changed;
- boot behavior;
- validation commands;
- recovery procedures;
- important failure modes.

## Configuration ownership

Where possible, generated lines and files should contain a `DeployScripts` marker. This makes later inspection and cleanup predictable.

Scripts should preserve unrelated configuration rather than replacing whole files unnecessarily.
