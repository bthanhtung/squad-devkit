# Wave 4A: sandbox platform spike

Date: 2026-11-24. Scope: evidence and proposed Wave 4B contract; no runtime
sandbox implementation is shipped by this document.

## Result and evidence limits

macOS Seatbelt successfully restricted writes and network connections while
running shell, Git worktree operations, Node and an offline Rust build. This is
sufficient to continue implementation experiments, **not** acceptance of a
production security boundary. The probe allowed all reads and most non-file
operations. A deny-by-default read/exec/Mach policy and authenticated engine turns
remain unverified. Do not deploy its profile as `strict`.

Host: Darwin 27.3.0, arm64; `/usr/bin/sandbox-exec` present. Installed commands:
Claude Code 2.1.325, codex-cli 0.172.0, Node at `/opt/homebrew/bin/node`,
Cargo 1.99.0 and rustc 1.99.0 via `$HOME/.cargo/bin`. OpenCode was present at
`$HOME/.opencode/bin/opencode`; `ccr`, `grok`, and `bwrap` were absent.
No real credential/configuration contents were inspected, no provider requests were made,
and no dependencies were installed. `uname -s` returned `Darwin`: this host is macOS, so Linux `bwrap` cannot
be executed locally. Its matrix entries are design requirements, not measured
results; Wave 4B must qualify them in Linux CI as described below.
Missing CCR/Grok and Linux tooling block those empirical checks; rerun on equipped
hosts before Wave 4B acceptance.

### Observed macOS probes

All writes were confined to disposable fixture directories outside the repository.
Git used a fresh fixture repository, never the real worktree's index or branches.

| Probe | Result |
| --- | --- |
| Write inside allowed temp subtree | Exit 0 |
| Write outside subtree | Exit 1, `Operation not permitted`; no file created |
| Initial shell and Git status without `/dev/null` write permission | Failed; shell redirection and Git opening `/dev/null` require it |
| Shell reading `/etc/hosts` after allowing `/dev/null` | Exit 0 |
| Git worktree add, status, add after allowing `/dev/null` | All exit 0; fixture common Git directory and worktree both inside allowed subtree |
| Node execution | Exit 0, `node-ok` |
| Cargo offline build of dependency-free binary and running it | Both exit 0, `rust-ok`; target and TMPDIR inside allowed subtree |
| Claude `--version` | Exit 0 |
| Codex `--version` | Exit 0, warning that PATH aliases could not be created |
| OpenCode `--version` | Exit 1; attempted write to `$HOME/.local/share/opencode/log/opencode.log` denied |
| TCP connect to a live controlled loopback listener | Host exit 0; sandbox exit 1, Python `PermissionError: [Errno 1]` |
| Curl to example.com with network denied | DNS failure; not used as proof of isolation because DNS failure is ambiguous |

The fixture Git test establishes ordinary shared-metadata access requirements,
not safe isolation of a real shared `.git`. Version checks do not establish login,
streaming, nested sandbox, or agent tool compatibility.

## Capability matrix

| Capability | macOS `sandbox-exec` | Linux `bwrap` | Missing/unsupported backend |
| --- | --- | --- | --- |
| Availability | Observed on this host; deprecated interface, probe each supported OS | Not observed; requires usable namespaces and installed binary | Treat absent binary, namespace denial, invalid profile and failed self-test alike |
| File writes | Empirically confined by Seatbelt path rules, including child tools | Explicit RW bind mounts; other mounts RO or absent; must test | No OS guarantee |
| File reads | Probe broad; production must deny sensitive reads explicitly | Empty mount tree exposes only selected paths | Engine permissions alone do not meet strict contract |
| Process execution | Shell, Node, Rust and Git observed; production exec/Mach rules pending | Bind executable/interpreter/library dependencies; isolate PID/IPC, drop capabilities | Never report wrapper as active |
| Network | `deny network*` blocked controlled TCP; domain filtering requires broker/proxy | `--unshare-net` isolates network; host loopback unavailable inside | Follow requested mode below |
| Shared Git metadata | Writable fixture common directory works; broad access unsafe | Mount common metadata RO, private worker index RW; broad RW unsafe | No silent shared-directory grant |
| IPC | Per-worker directory request/response and host SQLite insert passed; Unix socket untested | Same socket exposed alone, not DB directory; not tested | Strict launch blocked if required broker unavailable |
| Engine compatibility | Claude/Codex version only; OpenCode needs private writable state | All engines pending | Record unverified compatibility separately from backend presence |

Bubblewrap creates a mount namespace; network/PID and other namespaces require
explicit options. It is a policy-building primitive, not a complete policy.
Use `--unshare-all --die-with-parent --new-session --cap-drop ALL`, a minimal
`--dev`, private `--proc`, and explicit mounts; never `--ro-bind / /` for strict.
Do not use namespace `*-try` options or `--not-a-security-boundary` to pass strict
preflight. Kernel/container restrictions can reject an installed backend.
See [upstream README](https://github.com/containers/bubblewrap/blob/main/README.md)
and [option reference](https://github.com/containers/bubblewrap/blob/main/bwrap.xml).

## Filesystem and network allowlist contract

These are exact grants to generate from resolved paths, not a universal observed
engine allowlist. Provider/backend overrides and installed versions mean a single
static list cannot safely promise compatibility. Unknown paths/endpoints fail
closed in strict mode until added explicitly and tested. Never infer grants by
reading arbitrary user configuration or automatically widen after a denial.

Definitions: `W` = canonical worker worktree; `R` = manager-owned private per-run
runtime directory outside the shared `.squad`; `H=R/home`; `T=R/tmp`;
`G=git rev-parse --path-format=absolute --git-common-dir`; `I` = this worktree's
absolute git-dir. Compute Git paths before sandbox launch. Resolve symlinks,
reject unexpected roots, and generate safely escaped backend rules from trusted
paths. `W` can itself be nested below the manager's `.squad/worktrees`; allow W
specifically without allowing its parent. Enforce the same rules on gates and
all descendants, not only the agent's Bash tool.

| Resource | Required grant and exclusions |
| --- | --- |
| Worker files | W RW for developer; W RO for reviewer/scout. Deny repository-local `.squad` control data. Protect W/.git from modification. Approved input artifacts RO. Manager tree and sibling worktrees absent/denied for reads and writes |
| Temporary/output files | R's selected state/output subdirectories and T RW; HOME=H, TMPDIR=T, XDG_CONFIG_HOME=H/.config, XDG_CACHE_HOME=H/.cache, XDG_DATA_HOME=H/.local/share, XDG_STATE_HOME=H/.local/state. Reports/logs use per-run output grant or inherited streams, never whole manager output directory |
| System runtime | RO read/exec of resolved binaries and their interpreter/library closure: macOS `/bin`, `/usr/bin`, `/usr/lib`, `/System/Library`; selected `/Library/Developer/CommandLineTools` or selected Xcode SDK/toolchain. Homebrew: only selected resolved Cellar/opt dependencies under `/opt/homebrew` (Intel `/usr/local`), not entire writable prefix. Linux `/usr`, merged-/usr links or required `/bin`, `/lib`, `/lib64`; selected CA files and minimal loader/NSS files |
| Devices/system services | `/dev/null` RW observed necessary; `/dev/urandom` and `/dev/random` read, selected tty only if required. No host device tree. macOS dyld caches, SDK paths, DNS configuration and specific Mach services require tracing under final restrictive profile; no broad Keychain service grant |
| Node | Resolved Node/Bun and engine package files RO+exec; project node_modules in W. npm cache `H/.npm` RW, other package-manager caches under private XDG cache. No host `.npmrc` token or global package writes. Network installs opt-in; prefer prepopulated caches |
| Rust | Host rustup toolchains and cargo/rustc binaries RO+exec; private CARGO_HOME=H/.cargo with preseeded registry/git sources, private writable cache/index state. RUSTUP_HOME points to selected RO toolchain tree; no rustup updates. CARGO_TARGET_DIR=R/target RW (also for read-only roles). T RW for compiler/linker temporaries; selected SDK/linker RO |
| Credentials | Only selected provider credential supplied by launcher via narrow inherited environment or private 0600 file in H. Do not mount real HOME, `.ssh`, `.aws`, `.npmrc`, keychains, browser profiles or unrelated provider stores. Scrub environment; close unintended inherited FDs. Secrets never included in profile diagnostics/logs. Tokens visible to a worker can be read by its subprocesses; use a credential-injecting host proxy where that is unacceptable |
| Git | W/.git file RO; G objects, refs, packed-refs, HEAD, config and needed info files RO; I selected metadata RO plus private/per-worker index and index.lock RW only if staging is allowed. Redirect optional locks (`GIT_OPTIONAL_LOCKS=0`), disable hooks, fsmonitor and credential helpers via trusted config. Do not grant G RW merely to fix Git errors |
| IPC | Only R/ipc/ask.sock, with required parent traversal, plus selected egress socket. Never `$workspace_root/.squad/messages.db`, its WAL/SHM, or parent directory |

Production engine-specific starting grants (all private paths below H; existence
of host files need not be probed). These locations require installed-version tests:

| Engine | File/state grant | Egress grant |
| --- | --- | --- |
| claude | Resolved executable/package RO+exec; private `H/.claude` and `H/.claude.json` RW for selected settings/state; inject selected credential only. No-session-persistence does not prove zero state writes | HTTPS `api.anthropic.com:443` for direct API mode; explicit alternative provider endpoint if configured. OAuth/login/telemetry endpoints excluded until separately verified |
| codex | Resolved executable/package RO+exec; CODEX_HOME=H/.codex RW, sanitized config and selected auth provisioned there; alias/temp directories private | HTTPS `api.openai.com:443` for API mode; ChatGPT login/backend endpoints require separate tested allowlist; no implicit wildcard |
| opencode | Resolved binary/package RO+exec; `H/.config/opencode`, `H/.local/share/opencode`, `H/.local/state/opencode`, `H/.cache/opencode` RW. Host log failure above confirms writable data state is needed | Only explicitly selected provider's HTTPS endpoint; model catalog/download endpoints disabled or separately approved |
| ccr | Claude private state above; host router owns real router config/secrets/logs. Start router outside sandbox; replace current in-worker `ccr activate`/server startup with sanitized launch environment | Only a per-run router proxy endpoint; current default host `127.0.0.1:3456` or explicit configured port. Linux network namespace cannot reach host loopback; bridge via dedicated Unix socket proxy. Router permits only selected upstream provider |
| grok | Resolved executable/package RO+exec and private H/XDG state; actual version-specific config/cache filenames unverified because binary absent; fail strict compatibility preflight until tested | HTTPS `api.x.ai:443` only if selected direct API backend; other backends explicitly configured and tested |

HTTPS endpoints above are proposed direct-API grants, not captured traffic.
Default offline tool execution needs no egress. Optional downloads: exact
`registry.npmjs.org:443` for npm, `index.crates.io:443` and
`static.crates.io:443` for Cargo, selected HTTPS Git dependency hosts only.
Git fetch/push, SSH, arbitrary localhost/LAN, DNS and telemetry remain denied.
A proxy resolves DNS outside the sandbox, restricts CONNECT destination/port,
blocks private/link-local destinations and rechecks redirects/resolution.
Environment proxy variables alone are bypassable: OS rules must deny direct
sockets, UDP/QUIC and alternate IPv4/IPv6 routes. A domain allowlist also does
not prevent exfiltration to an allowed provider account.

## Shared Git and current integration gaps

`scripts/lib/squad-worktree.sh` snapshots through a temporary index, writes shared
objects via commit-tree, creates branches/worktree metadata, updates shared
info/exclude, and later stages/commits/merges/removes worktrees. Keep these
manager operations outside the worker sandbox. Shared refs/objects/config RW
would let a worker affect other workers and the manager. RO common Git metadata
can reveal repository history; it is not a confidentiality boundary between
branches. Strict secrecy needs an isolated repository/object copy.

For Wave 4B, workers edit files; the manager stages/commits and merges outside.
If worker-side Git staging is required, privately copy index state and expose
only that worker's locks, then test real linked-worktree paths. Deny direct
worker commit/worktree-add/ref updates. Submodules, Git LFS, alternates, hooks,
symlink swaps and credential helpers need explicit negative tests. Fixture
worktree creation succeeded only because all shared metadata was writable inside
the disposable allowed directory; that is not the proposed production grant.

Code inspected: `scripts/lib/engines/{claude,codex,opencode,ccr,grok}.sh`,
`scripts/squad-worker.sh`, `scripts/squad-ask.sh`, `scripts/lib/squad-worktree.sh`.
Claude and Codex add manager workspace access; remove that broad grant and supply
only worker inputs/IPC. Claude config enables its own shell sandbox; Codex sets
workspace-write/read-only unless bypassed. Neither replaces an outer wrapper.
OpenCode/CCR/Grok lack a common OS enforcement wrapper; Grok always approves.
Worker status currently reports `sandbox=none` for non-Codex engines, and gates
execute direct `bash -c`. Record actual outer backend separately and wrap gates.
Nested Claude/Codex sandbox behavior remains a required compatibility test.

## Minimal squad-ask IPC broker (production integration proposed)

Current `squad-ask.sh` changes into the manager workspace and calls `squad send`
and `squad receive`; `.squad` must exist. Do not pass that workspace through the
sandbox to preserve this implementation. Add a transport path to the same CLI:
when a launcher-provided broker endpoint is present, use it without opening or
checking manager paths. Preserve question/reply/check, bounded wait and timeout
semantics; no shell command or SQL transport.

1. Manager opens messages.db outside sandbox and creates a fresh R/ipc directory
   (0700) and Unix socket (0600) per run. Expose only that socket; do not expose
   other run sockets. Bind connection to run/attempt identity through the dedicated
   endpoint and a per-run capability delivered by inherited FD, never command
   arguments/logs. Same-UID peer credentials alone do not identify a worker.
2. Accept framed JSON `{version:1, op, to, message_id, text, timeout_seconds}`.
   Fix `from` and workspace server-side. Allow only send, receive/check, reply;
   validate recipient against this task's manager/allowed peers and authorize
   replies against messages delivered to this run. No DB paths, arbitrary SQL,
   filesystem paths, caller-supplied identity or arbitrary command operations.
3. Bound frame/text to 16 KiB, wait to 300 seconds, outstanding waits to one per
   run, and requests to 10/sec with bounded queue. Reject malformed/unknown fields,
   stale attempts and oversized frames before DB work. Use existing DB semantics
   and parameterized queries; receive only own mailbox, no global enumeration.
4. Return typed success/error/timeout and a correlation ID. Persist acknowledgement
   only after DB success. Reconnect retries must use request IDs for send/reply
   deduplication. Log IDs/status/size, not message text or capabilities.
5. Revoke capability and remove endpoint at worker termination; cancel waits on
   disconnect and enforce server deadlines. Broker failure is explicit, not direct
   SQLite fallback. Test broker restart/DB-busy handling and stale endpoint reuse.

An egress proxy and IPC broker have distinct permissions; neither accepts the
other's messages. Unix-socket access under restrictive Seatbelt and Linux mounts
must be verified, including sibling endpoint denial. The directory transport
prototype below was run; it does not implement this production protocol.

## Follow-up empirical IPC and engine startup probes

Executed on 2026-11-24 on the Darwin host above. All DB and engine state used
fresh disposable directories; the real manager DB and real credential files were
not opened by the probe. The host broker accepts exactly one fixed fixture
request and inserts via a parameterized query. Its sandboxed child can write only
its IPC subtree and `/dev/null`, while direct append to the fixture
`$workspace_root/.squad/messages.db` is denied. The host publishes an atomic
response after committing the insert. This proves the directory transport is
feasible with network completely denied; it does not qualify Unix sockets,
production identity checks, concurrent requests, or the existing squad-ask CLI.
The fixture uses the same `.squad/messages.db` versus `.squad/ipc/worker` layout
without risking the live manager database.

Exact reproduction command (Python 3; no additional packages):

```sh
cat > /tmp/wave4a-probe.py <<'PYPROBE'
import os, pathlib, tempfile, subprocess, sqlite3, time, json
r=pathlib.Path(tempfile.mkdtemp(prefix='wave4a-')).resolve()
(r/'workspace/.squad/ipc/worker').mkdir(parents=True)
ipc=r/'workspace/.squad/ipc/worker'; db=r/'workspace/.squad/messages.db'
c=sqlite3.connect(db); c.execute('create table messages(text)'); c.commit()
profile=r/'ipc.sb'
profile.write_text(f'''(version 1)
(allow default)
(deny file-write*)
(deny network*)
(allow file-write* (subpath "{ipc}") (literal "/dev/null"))
''')
child=r/'child.py'
child.write_text('''import pathlib,sys,time,json
p=pathlib.Path(sys.argv[1]); db=pathlib.Path(sys.argv[2])
try:
 with db.open('ab') as f: f.write(b'forbidden')
 raise AssertionError('DB write allowed')
except PermissionError: print('PASS direct messages.db write denied',flush=True)
(p/'request.json').write_text('{"op":"send","text":"fixture-ping"}')
for _ in range(100):
 if (p/'response.json').exists(): break
 time.sleep(.05)
assert json.loads((p/'response.json').read_text()) == {"ok":True}
print('PASS sandbox request/host response',flush=True)
''')
p=subprocess.Popen(['sandbox-exec','-f',str(profile),'/usr/bin/python3',str(child),str(ipc),str(db)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
for _ in range(100):
 if (ipc/'request.json').exists(): break
 time.sleep(.05)
req=json.loads((ipc/'request.json').read_text()); assert req=={'op':'send','text':'fixture-ping'}
c.execute('insert into messages values (?)',(req['text'],)); c.commit()
(ipc/'response.tmp').write_text('{"ok":true}'); (ipc/'response.tmp').rename(ipc/'response.json')
out,err=p.communicate(timeout=10); print(out,end=''); assert p.returncode==0,err
assert c.execute('select text from messages').fetchall()==[('fixture-ping',)]
print('PASS host SQLite insert and integrity'); c.close()
print('ROOT',r)
for engine,args in [('codex',['login','status']),('claude',['--print','--model','sonnet','fixture-ping'])]:
 h=r/engine; h.mkdir(); (h/'tmp').mkdir(); (h/'.cache').mkdir(); (h/'.codex').mkdir()
 env={'PATH':os.environ['PATH'],'HOME':str(h),'TMPDIR':str(h/'tmp'),'XDG_CONFIG_HOME':str(h/'.config'),'XDG_CACHE_HOME':str(h/'.cache'),'XDG_DATA_HOME':str(h/'.local/share'),'XDG_STATE_HOME':str(h/'.local/state'),'CODEX_HOME':str(h/'.codex'),'CLAUDE_CONFIG_DIR':str(h/'.claude'),'DISABLE_AUTOUPDATER':'1','DISABLE_TELEMETRY':'1'}
 for writable in [False,True]:
  sb=r/f'{engine}-{writable}.sb'; sb.write_text(f'''(version 1)
(allow default)
(deny file-write*)
(deny network*)
(allow file-write* (literal "/dev/null"){f' (subpath "{h / (".codex" if engine == "codex" else ".claude")}") (subpath "{h / "tmp"}")' if writable else ''})
''')
  try:
   result=subprocess.run(['sandbox-exec','-f',str(sb),engine,*args],env=env,text=True,capture_output=True,timeout=15)
   print(engine,'RW',writable,'EXIT',result.returncode,'OUTPUT', (result.stdout+result.stderr)[:1800])
  except subprocess.TimeoutExpired: print(engine,'RW',writable,'TIMEOUT 15s')
 print(engine,'CREATED', [str(x.relative_to(h)) for x in h.rglob('*')])
PYPROBE
python3 /tmp/wave4a-probe.py
```

Observed output (random ROOT and cache suffixes omitted):

```text
PASS direct messages.db write denied
PASS sandbox request/host response
PASS host SQLite insert and integrity
codex RW False EXIT 1 OUTPUT WARNING: proceeding, even though we could not create PATH aliases: Operation not permitted (os error 1)
Not logged in
codex RW True EXIT 1 OUTPUT Not logged in
claude RW False EXIT 1 OUTPUT Not logged in · Please run /login
claude RW True EXIT 1 OUTPUT Not logged in · Please run /login
```

The nonzero engine exits are expected unauthenticated results, not successful
agent turns. First run with a nonexistent CODEX_HOME failed configuration loading
even with writes allowed; explicitly creating that directory produced the above
results. With writes denied, Codex reported its alias failure; Claude still
reported missing login and did not surface a fatal state-write error.

Observed created paths with writes enabled (names only; contents not read):

| Engine | Private HOME paths created |
| --- | --- |
| Codex | `.codex/tmp/arg0-macos/codex-arg0<random>/{.lock,applypatch,apply_patch}` |
| Claude | `.claude/.claude.json`, `.claude/backups/.claude.json.backup.<timestamp>`, `.claude/plugins/store/cc-plugin-agents-md_builtin-<hash>.json`, `.claude/projects/<encoded-workspace>/<uuid>.jsonl`, project memory directories, `.claude/sessions` |
| Both | No files observed under the private `TMPDIR` or private XDG cache; these directories were created by the fixture before launch |

Exact tested engine write allowlist, with H resolved to its private canonical
HOME, layered over `(allow default)`, `(deny file-write*)`, `(deny network*)`:

```scheme
; Codex: CODEX_HOME=H/.codex (must already exist)
(allow file-write* (literal "/dev/null")
  (subpath "H/.codex") (subpath "H/tmp"))
; Claude: CLAUDE_CONFIG_DIR=H/.claude
(allow file-write* (literal "/dev/null")
  (subpath "H/.claude") (subpath "H/tmp"))
```

`H` in this explanatory block is a placeholder, not Seatbelt variable syntax;
the reproduction script interpolates absolute paths. No whole-HOME write grant
is needed for these startup commands. TMPDIR writes were permitted but not
observed, so their necessity is not established. The probe redirects credential
lookup to empty private stores and supplies no API-key environment variables.
It does not trace file reads: `(allow default)` still permits broad reads, so
there is **no empirically qualified credential read allowlist** here. Selected
auth-file reads, Keychain access, credential refresh, authenticated cache writes
and noninteractive turns require disposable provider accounts in Wave 4B.
Do not infer their sufficiency from a login-status/version check or grant real
HOME access to make authentication work.

## Missing-backend policy for Wave 4B

| Requested mode | Required behavior |
| --- | --- |
| `strict` | Default secure mode: missing/unsupported backend, failed negative self-test, invalid policy, unavailable required proxy/broker or incompatible engine prevents launch with nonzero result. No command/gate executes and no automatic engine-only fallback |
| `workspace` | Try OS wrapper. If backend is unavailable, explicitly warn on stderr and persist a warning event/status before starting engine workspace restrictions where supported. Record `backend=none`, `enforcement=engine-only` or `none`, requested/effective mode and reason; never claim OS isolation. Unsupported engine workspace restriction must be recorded as none |
| `off` | Intentionally disable outer wrapper; record requested/effective mode off and backend none. Engine permissions remain separately reported; do not imply this flag necessarily changes engine options |

Preflight must execute allowed and denied operations, not merely `which`.
Do not treat an actual child failure after sandbox launch as backend absence and
rerun it unsandboxed. Preserve the original failure; duplicated execution can
repeat destructive operations. Warnings must survive retries/resume and remain
visible in structured events/SQLite projections. The modes and fields here are
proposed contracts, not existing CLI flags.

## macOS caveats

`sandbox-exec` is deprecated; Seatbelt profiles and service dependencies vary by
OS/tool version. Confirm with local `man sandbox-exec` and requalify on upgrades.
It does not create a Linux-style private mount tree, user, PID or network namespace.
Path aliases (`/tmp` vs `/private/tmp`, `/var` vs `/private/var`), symlinks and
Homebrew indirection require canonical paths and adversarial tests. Broad read
access leaks credentials even when all writes are confined. Network and filesystem
isolation are both necessary; see the upstream
[Anthropic sandbox runtime](https://github.com/anthropics/sandbox-runtime/blob/main/README.md)
for native backends plus proxy filtering, and its
[filesystem/network rationale](https://www.anthropic.com/research/claude-code-sandboxing).

The initial `/dev/null` failure demonstrates that a narrow policy needs real
runtime testing. TCC, Keychain/Mach lookups, inherited descriptors, child process
control, Xcode licensing/SDK access and nested agent sandboxes are not settled by
version probes. Do not solve compatibility by granting all HOME, all Mach services,
all localhost, or disabling enforcement. Strict remains gated on negative tests.

## Reproduce the macOS write probe

Run in a disposable shell. This diagnostic profile deliberately allows reads and
non-network operations broadly; it is not the production strict profile.

```sh
probe_dir="$(mktemp -d)"
probe_dir="$(cd "$probe_dir" && pwd -P)"
mkdir "$probe_dir/allowed" "$probe_dir/denied"
cat > "$probe_dir/probe.sb" <<PROFILE
(version 1)
(allow default)
(deny file-write*)
(allow file-write* (subpath "$probe_dir/allowed") (literal "/dev/null"))
(deny network*)
PROFILE
sandbox-exec -f "$probe_dir/probe.sb" /bin/sh -c \
  'echo ok > "$1/ok"; cat /etc/hosts >/dev/null' sh "$probe_dir/allowed"
if sandbox-exec -f "$probe_dir/probe.sb" /bin/sh -c \
  'echo denied > "$1/no"' sh "$probe_dir/denied"; then
  echo 'FAIL: outside write allowed' >&2; exit 1
fi
test ! -e "$probe_dir/denied/no"
sandbox-exec -f "$probe_dir/probe.sb" node -e 'console.log("node-ok")'
sandbox-exec -f "$probe_dir/probe.sb" cargo --version
```

For the measured Rust build, create a dependency-free binary crate beneath allowed,
set TMPDIR to allowed and CARGO_TARGET_DIR to allowed/target, then run
`cargo build --offline --manifest-path "$probe_dir/allowed/crate/Cargo.toml"`
through the same wrapper and execute its binary. For Git, initialize a fresh repo
under allowed, make an empty fixture commit, then wrapper-run
`git -C "$probe_dir/allowed/repo" worktree add -b probe "$probe_dir/allowed/wt"`,
`git status`, and `git add`. Do not use the real repository for these write probes.

## Wave 4B verification gates

Linux is a **Linux CI-verified target for Wave 4B**, not a result claimed by
this macOS spike. Add `tests/squad_sandbox_isolation_smoke.sh` to `ubuntu-latest`
with `bwrap` installed and usable namespaces. That future test must exercise
allowed writes, denied control-path access, broker exchange, and backend failure.
When bwrap is missing or unusable, strict must fail before spawning any child;
workspace may proceed only with the explicit persisted fallback warning defined
above, and off must report no wrapper. CI must test the missing-bwrap branch
using a fixture PATH as well as the installed-backend branch; silently skipping
the Linux test does not qualify the target. This document does not add the test
or change CI configuration.

Concrete backend qualification commands (Linux requires that separate runner):

```sh
# macOS binary/profile execution
command -v sandbox-exec
sandbox-exec -p '(version 1)(allow default)' /usr/bin/true
# Linux namespace availability, not yet a complete policy
command -v bwrap
bwrap --version
bwrap --unshare-all --die-with-parent --new-session --cap-drop ALL \
  --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib \
  --symlink usr/lib64 /lib64 --proc /proc --dev /dev --tmpfs /tmp /bin/true
```

The Linux smoke command assumes merged-/usr; adapt explicit loader mounts to the
runner layout without granting `/`. Require failure when namespaces are denied.
Then run the generated final policy with all of these assertions on **both OSes**:

- Allowed W write succeeds; host/sibling/control-path writes and reads fail,
  including symlink, rename, hardlink, IPv6 and nested child-process attempts.
  Read-only roles cannot write W but can compile into R/target.
- A host-controlled listener accepts an unsandboxed control connection; the same
  direct connect in sandbox fails. The approved proxy works; other localhost,
  LAN, DNS and internet endpoints fail even with proxy variables removed.
- Shell, Node fixture tests and dependency-free offline Cargo build pass; Git
  status/diff pass with G RO. Shared ref/config writes and unauthorized index
  updates fail. Hooks/helpers cannot bypass controls.
- In disposable provider accounts, each installed engine completes one minimal
  non-interactive turn, edit/read-only tool check and nested shell operation.
  Confirm actual auth refresh/cache writes without dumping credentials. Repeat
  with engine sandbox enabled; test CCR through host proxy, not host loopback.
- Broker send/check/reply/timeout work; DB/WAL/SHM and sibling socket access fail.
  Spoofed identity, stale capability, oversized frame and unauthorized recipient
  fail. Broker loss yields explicit error, with no direct DB fallback.
- A gate attempting an outside write fails under the same wrapper. Missing binary,
  invalid profile and namespace denial fail strict before child execution;
  workspace persists its fallback warning; off records no wrapper. Test this by
  replacing the backend in a fixture PATH, never uninstalling system tools.

Acceptance remains pending Linux execution, full read isolation, engine turns,
private shared-Git layout, production broker/proxy and missing-backend integration.
The directory broker prototype above is measured; production integration remains pending. The only
repository verification required for this documentation change is:

```sh
test -s docs/testing/sandbox-platform-matrix.md
```
