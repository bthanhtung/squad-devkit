use jaq_core::data::JustLut;
use jaq_core::load::{Arena, File, Loader};
use jaq_core::{Compiler, Ctx, Vars};
use jaq_json::Val;
use std::io::{BufRead, BufReader, Read, Write};

const PRELUDE: &str = "\
def IN(s): . as $in | [s] | any(. == $in);
def IN(src; s): src as $in | [s] | any(. == $in);
def @tsv: map(if type == \"string\" then . else tostring end) | join(\"\\t\");
def @csv: map(if type == \"string\" then . else tostring end) | join(\",\");
";

fn normalize_filter_escapes(code: &str) -> String {
    // Replace \p{Cc} (unicode control characters) with [:cntrl:] which regex-bites supports.
    // Replace non-standard JSON escape sequences (e.g. \s, \S, \d, \D, \w, \W) in string literals
    // with double backslashes so jaq string lexer accepts them.
    let code = code.replace(r"\\p{Cc}", "[:cntrl:]").replace(r"\p{Cc}", "[:cntrl:]");
    let mut out = String::with_capacity(code.len() + 16);
    let mut chars = code.chars().peekable();
    let mut in_string = false;

    while let Some(c) = chars.next() {
        if !in_string {
            if c == '"' {
                in_string = true;
            }
            out.push(c);
        } else if c == '"' {
            in_string = false;
            out.push(c);
        } else if c == '\\' {
            if let Some(&next_c) = chars.peek() {
                match next_c {
                    '\\' => {
                        out.push('\\');
                        out.push('\\');
                        chars.next();
                    }
                    '"' | '/' | 'b' | 'f' | 'n' | 'r' | 't' | 'u' | '(' => {
                        out.push('\\');
                        out.push(chars.next().unwrap());
                    }
                    _ => {
                        out.push('\\');
                        out.push('\\');
                    }
                }
            } else {
                out.push('\\');
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub fn command(args: Vec<String>) -> anyhow::Result<()> {
    let stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let mut stderr = std::io::stderr();
    let code = run(&args, stdin.lock(), &mut stdout, &mut stderr);
    std::process::exit(code);
}

pub fn run<R: Read, W: Write, E: Write>(
    args: &[String],
    stdin: R,
    stdout: &mut W,
    stderr: &mut E,
) -> i32 {
    let mut raw_output = false;
    let mut exit_status = false;
    let mut compact_output = false;
    let mut slurp = false;
    let mut raw_input = false;
    let mut null_input = false;
    let mut named_args: Vec<(String, Val)> = Vec::new();
    let mut positional_args: Vec<String> = Vec::new();
    let mut filter_str: Option<String> = None;
    let mut file_args: Vec<String> = Vec::new();

    let mut i = 0;
    let mut in_options = true;
    let mut args_mode = false;

    while i < args.len() {
        let arg = &args[i];
        if in_options && arg == "--" {
            in_options = false;
            i += 1;
            continue;
        }
        if in_options && !args_mode && arg.starts_with('-') && arg != "-" {
            match arg.as_str() {
                "--raw-output" => raw_output = true,
                "--exit-status" => exit_status = true,
                "--compact-output" => compact_output = true,
                "--slurp" => slurp = true,
                "--raw-input" => raw_input = true,
                "--null-input" => null_input = true,
                "--arg" => {
                    if i + 2 >= args.len() {
                        let _ = writeln!(stderr, "squad jq: --arg requires two arguments: NAME VALUE");
                        return 2;
                    }
                    named_args.push((args[i + 1].clone(), Val::from(args[i + 2].clone())));
                    i += 3;
                    continue;
                }
                "--argjson" => {
                    if i + 2 >= args.len() {
                        let _ = writeln!(stderr, "squad jq: --argjson requires two arguments: NAME JSON");
                        return 2;
                    }
                    let val = match jaq_json::read::parse_single(args[i + 2].as_bytes()) {
                        Ok(v) => v,
                        Err(e) => {
                            let _ = writeln!(
                                stderr,
                                "squad jq: invalid JSON text passed to --argjson: {e}"
                            );
                            return 2;
                        }
                    };
                    named_args.push((args[i + 1].clone(), val));
                    i += 3;
                    continue;
                }
                "--args" => {
                    args_mode = true;
                    i += 1;
                    continue;
                }
                "--help" | "-h" => {
                    let _ = writeln!(stdout, "Usage: squad jq [OPTIONS] FILTER [FILE...]");
                    return 0;
                }
                _ if arg.starts_with("--") => {
                    let _ = writeln!(stderr, "squad jq: unknown option: {arg}");
                    return 2;
                }
                _ => {
                    for ch in arg[1..].chars() {
                        match ch {
                            'r' => raw_output = true,
                            'e' => exit_status = true,
                            'c' => compact_output = true,
                            's' => slurp = true,
                            'R' => raw_input = true,
                            'n' => null_input = true,
                            other => {
                                let _ = writeln!(stderr, "squad jq: unknown option: -{other}");
                                return 2;
                            }
                        }
                    }
                }
            }
            i += 1;
        } else {
            if filter_str.is_none() {
                filter_str = Some(arg.clone());
            } else if args_mode {
                positional_args.push(arg.clone());
            } else {
                file_args.push(arg.clone());
            }
            i += 1;
        }
    }

    let filter_str = match filter_str {
        Some(f) => f,
        None => {
            let _ = writeln!(stderr, "squad jq: missing filter");
            return 2;
        }
    };

    // Deduplicate named args (latest wins)
    let mut deduped_named: Vec<(String, Val)> = Vec::new();
    for (name, val) in named_args {
        if let Some(pos) = deduped_named.iter().position(|(n, _)| n == &name) {
            deduped_named[pos] = (name, val);
        } else {
            deduped_named.push((name, val));
        }
    }

    let mut var_names: Vec<&'static str> = Vec::new();
    let mut var_values: Vec<Val> = Vec::new();
    let mut named_map = jaq_json::Map::default();

    for (name, val) in &deduped_named {
        let var_name = if name.starts_with('$') {
            name.clone()
        } else {
            format!("${name}")
        };
        var_names.push(Box::leak(var_name.into_boxed_str()));
        var_values.push(val.clone());
        named_map.insert(Val::from(name.clone()), val.clone());
    }

    let pos_vals: Vec<Val> = positional_args
        .iter()
        .map(|s| Val::from(s.clone()))
        .collect();
    let mut args_map = jaq_json::Map::default();
    args_map.insert(Val::from("named".to_string()), Val::obj(named_map));
    args_map.insert(
        Val::from("positional".to_string()),
        Val::Arr(std::rc::Rc::new(pos_vals)),
    );
    var_names.push("$ARGS");
    var_values.push(Val::obj(args_map));

    let defs = jaq_core::defs().chain(jaq_std::defs()).chain(jaq_json::defs());
    let funs = jaq_core::funs::<JustLut<Val>>()
        .chain(jaq_std::funs())
        .chain(jaq_json::funs());
    let loader = Loader::new(defs);
    let arena = Arena::default();
    let normalized_code = normalize_filter_escapes(&filter_str);
    let mut full_code = String::with_capacity(PRELUDE.len() + normalized_code.len());
    full_code.push_str(PRELUDE);
    full_code.push_str(&normalized_code);
    let program = File {
        code: &*Box::leak(full_code.into_boxed_str()),
        path: (),
    };
    let modules = match loader.load(&arena, program) {
        Ok(m) => m,
        Err(e) => {
            let _ = writeln!(stderr, "squad jq: parse error: {:?}", e);
            return 5;
        }
    };

    let filter = match Compiler::default()
        .with_global_vars(var_names)
        .with_funs(funs)
        .compile(modules)
    {
        Ok(f) => f,
        Err(errs) => {
            let _ = writeln!(stderr, "squad jq: compile error: {:?}", errs);
            return 5;
        }
    };

    let pp = jaq_json::write::Pp {
        indent: if compact_output {
            None
        } else {
            Some("  ".to_string())
        },
        sep_space: !compact_output,
        sort_keys: false,
        styles: jaq_json::write::Styles::default(),
    };

    let mut output_count = 0usize;
    let mut last_val_is_false_or_null = false;

    let mut eval_val = |val: Val| -> Result<(), i32> {
        let ctx = Ctx::<JustLut<Val>>::new(&filter.lut, Vars::new(var_values.clone()));
        for result in filter.id.run((ctx, val)) {
            match result {
                Ok(out_val) => {
                    output_count += 1;
                    last_val_is_false_or_null = matches!(out_val, Val::Bool(false) | Val::Null);
                    if raw_output {
                        if let Ok(bytes) = out_val.try_as_bytes_owned() {
                            let _ = stdout.write_all(&bytes);
                            let _ = stdout.write_all(b"\n");
                        } else {
                            let _ = jaq_json::write::write(stdout, &pp, 0, &out_val);
                            let _ = stdout.write_all(b"\n");
                        }
                    } else {
                        let _ = jaq_json::write::write(stdout, &pp, 0, &out_val);
                        let _ = stdout.write_all(b"\n");
                    }
                }
                Err(e) => {
                    let _ = writeln!(stderr, "squad jq: error: {e:?}");
                    return Err(5);
                }
            }
        }
        Ok(())
    };

    if null_input {
        if let Err(code) = eval_val(Val::Null) {
            return code;
        }
    } else {
        // Collect readers for files or stdin
        enum ReaderSource<R> {
            Stdin(Option<R>),
            Path(String),
        }

        let sources = if file_args.is_empty() {
            vec![ReaderSource::Stdin(Some(stdin))]
        } else {
            let mut s = Vec::new();
            let mut stdin_opt = Some(stdin);
            for f in file_args {
                if f == "-" {
                    s.push(ReaderSource::Stdin(stdin_opt.take()));
                } else {
                    s.push(ReaderSource::Path(f));
                }
            }
            s
        };

        if raw_input && slurp {
            let mut combined = String::new();
            for src in sources {
                match src {
                    ReaderSource::Stdin(Some(mut r)) => {
                        if let Err(e) = r.read_to_string(&mut combined) {
                            let _ = writeln!(stderr, "squad jq: read error: {e}");
                            return 2;
                        }
                    }
                    ReaderSource::Stdin(None) => {}
                    ReaderSource::Path(p) => match std::fs::File::open(&p) {
                        Ok(mut f) => {
                            if let Err(e) = f.read_to_string(&mut combined) {
                                let _ = writeln!(stderr, "squad jq: read error: {e}");
                                return 2;
                            }
                        }
                        Err(e) => {
                            let _ = writeln!(stderr, "squad jq: error: Could not open file {p}: {e}");
                            return 2;
                        }
                    },
                }
            }
            if let Err(code) = eval_val(Val::utf8_str(combined.into_bytes())) {
                return code;
            }
        } else if slurp {
            let mut all_vals = Vec::new();
            for src in sources {
                match src {
                    ReaderSource::Stdin(Some(r)) => {
                        let reader = BufReader::new(r);
                        for item in jaq_json::read::read_many(reader) {
                            match item {
                                Ok(val) => all_vals.push(val),
                                Err(e) => {
                                    let _ = writeln!(stderr, "squad jq: parse error: {e}");
                                    return 5;
                                }
                            }
                        }
                    }
                    ReaderSource::Stdin(None) => {}
                    ReaderSource::Path(p) => match std::fs::File::open(&p) {
                        Ok(f) => {
                            let reader = BufReader::new(f);
                            for item in jaq_json::read::read_many(reader) {
                                match item {
                                    Ok(val) => all_vals.push(val),
                                    Err(e) => {
                                        let _ = writeln!(stderr, "squad jq: parse error: {e}");
                                        return 5;
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            let _ = writeln!(stderr, "squad jq: error: Could not open file {p}: {e}");
                            return 2;
                        }
                    },
                }
            }
            if let Err(code) = eval_val(Val::Arr(std::rc::Rc::new(all_vals))) {
                return code;
            }
        } else if raw_input {
            for src in sources {
                let lines: Box<dyn Iterator<Item = std::io::Result<String>>> = match src {
                    ReaderSource::Stdin(Some(r)) => Box::new(BufReader::new(r).lines()),
                    ReaderSource::Stdin(None) => Box::new(std::iter::empty()),
                    ReaderSource::Path(p) => match std::fs::File::open(&p) {
                        Ok(f) => Box::new(BufReader::new(f).lines()),
                        Err(e) => {
                            let _ = writeln!(stderr, "squad jq: error: Could not open file {p}: {e}");
                            return 2;
                        }
                    },
                };
                for line in lines {
                    match line {
                        Ok(l) => {
                            if let Err(code) = eval_val(Val::utf8_str(l.into_bytes())) {
                                return code;
                            }
                        }
                        Err(e) => {
                            let _ = writeln!(stderr, "squad jq: read error: {e}");
                            return 2;
                        }
                    }
                }
            }
        } else {
            for src in sources {
                match src {
                    ReaderSource::Stdin(Some(r)) => {
                        let reader = BufReader::new(r);
                        for item in jaq_json::read::read_many(reader) {
                            match item {
                                Ok(val) => {
                                    if let Err(code) = eval_val(val) {
                                        return code;
                                    }
                                }
                                Err(e) => {
                                    let _ = writeln!(stderr, "squad jq: parse error: {e}");
                                    return 5;
                                }
                            }
                        }
                    }
                    ReaderSource::Stdin(None) => {}
                    ReaderSource::Path(p) => match std::fs::File::open(&p) {
                        Ok(f) => {
                            let reader = BufReader::new(f);
                            for item in jaq_json::read::read_many(reader) {
                                match item {
                                    Ok(val) => {
                                        if let Err(code) = eval_val(val) {
                                            return code;
                                        }
                                    }
                                    Err(e) => {
                                        let _ = writeln!(stderr, "squad jq: parse error: {e}");
                                        return 5;
                                    }
                                }
                            }
                        }
                        Err(e) => {
                            let _ = writeln!(stderr, "squad jq: error: Could not open file {p}: {e}");
                            return 2;
                        }
                    },
                }
            }
        }
    }

    if exit_status {
        if output_count == 0 {
            4
        } else if last_val_is_false_or_null {
            1
        } else {
            0
        }
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_test(args: &[&str], input: &str) -> (i32, String, String) {
        let string_args: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        let code = run(
            &string_args,
            input.as_bytes(),
            &mut stdout,
            &mut stderr,
        );
        (
            code,
            String::from_utf8_lossy(&stdout).into_owned(),
            String::from_utf8_lossy(&stderr).into_owned(),
        )
    }

    #[test]
    fn test_basic_pretty_and_compact() {
        let (code, out, _) = run_test(&["."], "{\"b\":2,\"a\":1}");
        assert_eq!(code, 0);
        assert_eq!(out, "{\n  \"b\": 2,\n  \"a\": 1\n}\n");

        let (code, out, _) = run_test(&["-c", "."], "{\"b\":2,\"a\":1}");
        assert_eq!(code, 0);
        assert_eq!(out, "{\"b\":2,\"a\":1}\n");
    }

    #[test]
    fn test_raw_output() {
        let (code, out, _) = run_test(&["-r", ".name"], "{\"name\":\"squad\"}");
        assert_eq!(code, 0);
        assert_eq!(out, "squad\n");

        // Non-string under -r is still printed as json
        let (code, out, _) = run_test(&["-r", ".num"], "{\"num\":42}");
        assert_eq!(code, 0);
        assert_eq!(out, "42\n");
    }

    #[test]
    fn test_exit_status() {
        // Truthy
        let (code, _, _) = run_test(&["-e", "."], "true");
        assert_eq!(code, 0);

        // False
        let (code, _, _) = run_test(&["-e", "."], "false");
        assert_eq!(code, 1);

        // Null
        let (code, _, _) = run_test(&["-e", "."], "null");
        assert_eq!(code, 1);

        // Empty output
        let (code, _, _) = run_test(&["-e", "empty"], "1");
        assert_eq!(code, 4);

        // Without -e, false/null/empty exit 0
        let (code, _, _) = run_test(&["."], "false");
        assert_eq!(code, 0);
        let (code, _, _) = run_test(&["."], "null");
        assert_eq!(code, 0);
        let (code, _, _) = run_test(&["empty"], "1");
        assert_eq!(code, 0);
    }

    #[test]
    fn test_null_input() {
        let (code, out, _) = run_test(&["-n", "1 + 2"], "");
        assert_eq!(code, 0);
        assert_eq!(out, "3\n");
    }

    #[test]
    fn test_slurp() {
        let (code, out, _) = run_test(&["-s", "-c", "."], "1\n2\n3");
        assert_eq!(code, 0);
        assert_eq!(out, "[1,2,3]\n");
    }

    #[test]
    fn test_raw_input() {
        let (code, out, _) = run_test(&["-R", "-c", "."], "foo\nbar");
        assert_eq!(code, 0);
        assert_eq!(out, "\"foo\"\n\"bar\"\n");
    }

    #[test]
    fn test_raw_input_and_slurp() {
        let (code, out, _) = run_test(&["-Rrs", "."], "foo\nbar\n");
        assert_eq!(code, 0);
        assert_eq!(out, "foo\nbar\n\n");
    }

    #[test]
    fn test_args_and_variables() {
        let (code, out, _) = run_test(
            &[
                "-n",
                "-c",
                "--arg",
                "x",
                "hello",
                "--argjson",
                "y",
                "[1,2]",
                "[$x, $y, $ARGS.named.x, $ARGS.named.y]",
            ],
            "",
        );
        assert_eq!(code, 0);
        assert_eq!(out, "[\"hello\",[1,2],\"hello\",[1,2]]\n");
    }

    #[test]
    fn test_positional_args() {
        let (code, out, _) = run_test(
            &[
                "-n",
                "-c",
                "--args",
                "{permissions:{allow:$ARGS.positional}}",
                "rule1",
                "rule2",
            ],
            "",
        );
        assert_eq!(code, 0);
        assert_eq!(out, "{\"permissions\":{\"allow\":[\"rule1\",\"rule2\"]}}\n");
    }

    #[test]
    fn test_combined_short_flags() {
        // -er
        let (code, out, _) = run_test(&["-er", ".name"], "{\"name\":\"test\"}");
        assert_eq!(code, 0);
        assert_eq!(out, "test\n");

        let (code, _, _) = run_test(&["-er", ".name"], "{\"name\":null}");
        assert_eq!(code, 1);

        // -cn
        let (code, out, _) = run_test(&["-cn", "{a: 1}"], "");
        assert_eq!(code, 0);
        assert_eq!(out, "{\"a\":1}\n");

        // -nc
        let (code, out, _) = run_test(&["-nc", "{b: 2}"], "");
        assert_eq!(code, 0);
        assert_eq!(out, "{\"b\":2}\n");
    }

    #[test]
    fn test_error_exit_codes() {
        // Parse error in json: exit 5
        let (code, _, err) = run_test(&["."], "bad json");
        assert_eq!(code, 5);
        assert!(err.contains("parse error"));

        // Compile error in filter: exit 5
        let (code, _, err) = run_test(&["invalid [["], "{}");
        assert_eq!(code, 5);
        assert!(err.contains("parse error") || err.contains("compile error"));

        // Usage error: unknown option: exit 2
        let (code, _, err) = run_test(&["-z", "."], "{}");
        assert_eq!(code, 2);
        assert!(err.contains("unknown option"));

        // Usage error: missing filter: exit 2
        let (code, _, err) = run_test(&[], "{}");
        assert_eq!(code, 2);
        assert!(err.contains("missing filter"));

        // Usage error: invalid argjson: exit 2
        let (code, _, err) = run_test(&["-n", "--argjson", "x", "bad json", "."], "");
        assert_eq!(code, 2);
        assert!(err.contains("invalid JSON"));
    }

    #[test]
    fn test_regex_with_escapes() {
        let (code, out, _) = run_test(&["-n", "-c", r#""valid-model" | test("[\s\p{Cc}]") | not"#], "");
        assert_eq!(code, 0);
        assert_eq!(out, "true\n");

        let (code, out, _) = run_test(&["-n", "-c", r#""bad model" | test("[\s\p{Cc}]") | not"#], "");
        assert_eq!(code, 0);
        assert_eq!(out, "false\n");
    }
}
