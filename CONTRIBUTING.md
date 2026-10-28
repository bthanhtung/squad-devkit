# Contributing

Thanks for helping improve squad-devkit. This repository contains the `squad`
CLI (Rust, from [mco-org/squad](https://github.com/mco-org/squad)) and
squad-devkit, the manager-and-workers layer built from shell scripts in
`scripts/` and role prompts in `templates/devkit/`.

## Development setup

```bash
brew install jq tmux ripgrep shellcheck   # or your platform's equivalents
cargo build
export PATH="$PWD/target/debug:$PATH"     # use the squad binary you just built
```

## Before you open a pull request

Run the same checks as CI:

```bash
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all
shellcheck -S warning scripts/*.sh scripts/lib/squad-devkit-*.sh
bash tests/squad_devkit_launcher_smoke.sh
bash tests/squad_devkit_manager_choice_smoke.sh
bash tests/squad_worker_smoke.sh
bash tests/squad_devkit_clean_smoke.sh
```

The smoke tests use fake `claude`, `codex`, and other CLIs, so they make no
model calls and need no accounts.

## Guidelines

- **Scripts** target bash 3.2 (the macOS default) as well as bash 5. Keep
  `set -euo pipefail`, quote every expansion, and avoid GNU-only flags; when a
  tool differs between macOS and Linux (`stat`, `date`), support both.
- **Tests**: macOS bash 3.2 does not exit on a failed `[[ ... ]]` under
  `set -e`, so write assertions as `[[ ... ]] || fail`. Do not pipe a command
  into `grep -q` under `pipefail`; use `grep -q pattern <<<"$(command)"`.
- **Prompts** (`templates/devkit/*.md`) are read by models on every run: keep
  them short, concrete, and free of repetition, because every word costs tokens.
- **Security**: never log, print, or commit credentials. Worker prompts must not
  encourage reading secrets from configuration files.
- **Compatibility**: new options need a default that keeps existing behavior.
  Document user-visible changes in `CHANGELOG.md` and `docs/squad-devkit.md`.

## Reporting bugs and requesting features

Open an issue with the command you ran, what you expected, what happened, and
your OS, shell, and CLI versions. For security issues, follow
[SECURITY.md](./SECURITY.md) instead of opening a public issue.
