## Summary

<!-- What does this change, and why? Link the issue it addresses. -->

## How it was tested

<!-- Commands you ran and their results. Note anything verified only with stand-in CLIs. -->

## Checklist

- [ ] `shellcheck -S warning` passes for changed scripts
- [ ] The devkit smoke tests pass (`bash tests/squad_*_smoke.sh`)
- [ ] `cargo fmt`, `cargo clippy`, and `cargo test` pass if Rust code changed
- [ ] Works on bash 3.2 (macOS) and bash 5 (Linux)
- [ ] User-visible changes are documented in `README.md`, `docs/squad-devkit.md`, and `CHANGELOG.md`
- [ ] No credentials, internal hostnames, or personal data in code, tests, or logs
