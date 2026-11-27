//! Native filesystem isolation for worker commands and gates.
use anyhow::{bail, Context, Result};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

#[derive(Default)]
struct Options {
    worktree: PathBuf,
    tmp: Option<PathBuf>,
    git: Option<PathBuf>,
    ro: Vec<PathBuf>,
    readonly: bool,
    network: bool,
    strict: bool,
}

fn canonical(value: &str) -> Result<PathBuf> {
    let path = Path::new(value)
        .canonicalize()
        .context("sandbox path must exist")?;
    path.to_str().context("sandbox paths must be UTF-8")?;
    if !path.is_dir() || path == Path::new("/") {
        bail!("sandbox paths must be directories other than root");
    }
    Ok(path)
}

fn quoted(path: &Path) -> String {
    serde_json::to_string(&path.to_string_lossy()).expect("path string")
}

fn backend(options: &Options) -> Command {
    if cfg!(target_os = "macos") {
        let mut policy = if options.strict {
            "(version 1)(deny default)(allow process*)(allow sysctl-read)(allow mach-lookup)(allow file-read* (literal \"/\"))"
                .to_string()
        } else {
            "(version 1)(allow default)(deny file-write*)".to_string()
        };
        if options.strict {
            for path in [
                "/bin",
                "/usr/bin",
                "/usr/lib",
                "/System/Library",
                "/Library/Developer/CommandLineTools",
                "/opt/homebrew",
                "/usr/local",
                "/dev/null",
                "/dev/urandom",
                "/dev/random",
                "/private/var/select/sh",
            ] {
                policy.push_str(&format!(
                    "(allow file-read* (subpath {}))",
                    quoted(Path::new(path))
                ));
            }
            for path in std::iter::once(&options.worktree)
                .chain(options.ro.iter())
                .chain(options.git.iter())
            {
                policy.push_str(&format!("(allow file-read* (subpath {}))", quoted(path)));
            }
        }
        policy.push_str("(allow file-write* (literal \"/dev/null\"))");
        if !options.readonly {
            policy.push_str(&format!(
                "(allow file-write* (subpath {}))",
                quoted(&options.worktree)
            ));
        }
        if let Some(tmp) = &options.tmp {
            policy.push_str(&format!(
                "(allow file-read* file-write* (subpath {}))",
                quoted(tmp)
            ));
        }
        if !options.strict {
            if let Some(git) = &options.git {
                policy.push_str(&format!("(allow file-write* (subpath {}))", quoted(git)));
            }
        }
        if !options.network {
            policy.push_str("(deny network*)");
        } else if options.strict {
            policy.push_str("(allow network*)");
        }
        let mut cmd = Command::new("sandbox-exec");
        cmd.args(["-p", &policy]);
        cmd
    } else {
        let mut cmd = Command::new("bwrap");
        cmd.args([
            "--unshare-all",
            "--die-with-parent",
            "--new-session",
            "--cap-drop",
            "ALL",
        ]);
        if options.network {
            cmd.arg("--share-net");
        }
        if options.strict {
            for path in ["/usr", "/bin", "/lib", "/lib64"] {
                if Path::new(path).exists() {
                    if let Ok(metadata) = std::fs::symlink_metadata(path) {
                        if metadata.file_type().is_symlink() {
                            if let Ok(target) = std::fs::read_link(path) {
                                cmd.args(["--symlink"]).arg(target).arg(path);
                                continue;
                            }
                        }
                    }
                    cmd.args(["--ro-bind", path, path]);
                }
            }
        } else {
            cmd.args(["--ro-bind", "/", "/"]);
        }
        cmd.args(["--proc", "/proc", "--dev", "/dev"]);
        for path in options.ro.iter().chain(options.git.iter()) {
            cmd.arg(if !options.strict && options.git.as_ref() == Some(path) {
                "--bind"
            } else {
                "--ro-bind"
            })
            .arg(path)
            .arg(path);
        }
        cmd.arg(if options.readonly {
            "--ro-bind"
        } else {
            "--bind"
        })
        .arg(&options.worktree)
        .arg(&options.worktree);
        if let Some(tmp) = &options.tmp {
            cmd.arg("--bind").arg(tmp).arg(tmp);
        }
        if options.strict {
            cmd.args(["--remount-ro", "/"]);
        }
        cmd
    }
}

pub fn command(args: &[String]) -> Result<i32> {
    if args.first().map(String::as_str) != Some("exec") {
        bail!(
            "Usage: squad sandbox exec --worktree DIR [--profile strict|workspace|off] -- CMD..."
        );
    }
    let mut options = Options {
        strict: true,
        ..Options::default()
    };
    let mut off = false;
    let mut i = 1;
    while i < args.len() && args[i] != "--" {
        let flag = args[i].as_str();
        if flag == "--readonly" {
            options.readonly = true;
            i += 1;
            continue;
        }
        let value = args.get(i + 1).context("missing sandbox option value")?;
        match flag {
            "--worktree" => options.worktree = canonical(value)?,
            "--run-tmp" => options.tmp = Some(canonical(value)?),
            "--git-common-dir" => options.git = Some(canonical(value)?),
            "--ro-path" => options.ro.push(canonical(value)?),
            "--profile" => match value.as_str() {
                "strict" => {
                    options.strict = true;
                    off = false;
                }
                "workspace" => {
                    options.strict = false;
                    off = false;
                }
                "off" => off = true,
                _ => bail!("invalid sandbox profile"),
            },
            "--network" => match value.as_str() {
                "allow" => options.network = true,
                "deny" => options.network = false,
                _ => bail!("invalid sandbox network policy"),
            },
            _ => bail!("unknown sandbox option: {flag}"),
        }
        i += 2;
    }
    let child = args
        .get(i + 1..)
        .filter(|v| !v.is_empty())
        .context("sandbox requires -- CMD")?;
    if options.worktree.as_os_str().is_empty() {
        bail!("--worktree is required");
    }
    let mut isolated = !off;
    if isolated {
        // Probe before the actual child: never rerun a failing child outside isolation.
        let probe = std::env::temp_dir().join(format!("squad-sandbox-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&probe).context("create sandbox preflight fixture")?;
        let probe = probe.canonicalize()?;
        let secret = probe.join("secret");
        std::fs::write(&secret, b"preflight")?;
        let script = if options.strict {
            "test -r /bin/sh || exit 1; if /bin/cat \"$1\" >/dev/null 2>&1; then exit 1; fi; if (echo denied >\"$2\") 2>/dev/null; then exit 1; fi; if [ \"$3\" = readonly ] && (echo denied >\"$4\") 2>/dev/null; then exit 1; fi; printf sandbox-preflight-ok"
        } else {
            "test -r /bin/sh || exit 1; if (echo denied >\"$2\") 2>/dev/null; then exit 1; fi; printf sandbox-preflight-ok"
        };
        let mut probe_command = backend(&options);
        probe_command
            .args(["/bin/sh", "-c", script, "sh"])
            .arg(&secret)
            .arg(probe.join("outside"))
            .current_dir(&options.worktree);
        if options.strict {
            probe_command.arg(if options.readonly {
                "readonly"
            } else {
                "write"
            });
            probe_command.arg(options.worktree.join(".squad-preflight-write"));
        }
        let usable = probe_command
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .is_ok_and(|out| out.status.success() && out.stdout == b"sandbox-preflight-ok");
        let _ = std::fs::remove_dir_all(&probe);
        if !usable {
            if options.strict {
                bail!("strict sandbox backend missing or preflight failed");
            }
            eprintln!("WARNING: sandbox backend unavailable; profile=workspace backend=none enforcement=none; running directly");
            isolated = false;
        }
    }
    let mut cmd = if isolated {
        backend(&options)
    } else {
        Command::new(&child[0])
    };
    if isolated {
        cmd.arg(&child[0]);
    }
    cmd.args(&child[1..]).current_dir(&options.worktree);
    if let Some(tmp) = options.tmp {
        cmd.env("TMPDIR", tmp);
    }
    Ok(cmd
        .status()
        .context("execute sandbox child")?
        .code()
        .unwrap_or(1))
}
