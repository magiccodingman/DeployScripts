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
