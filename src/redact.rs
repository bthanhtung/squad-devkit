use anyhow::{bail, Result};
use std::io::{Read, Write};

/// Redact known secret values and common credential assignments without logging them.
pub fn redact(input: &str) -> String {
    let mut output = input.to_owned();
    let mut secrets: Vec<String> = std::env::vars()
        .filter(|(key, value)| {
            let key = key.to_ascii_uppercase();
            value.len() >= 8
                && ["TOKEN", "SECRET", "PASSWORD", "API_KEY", "PRIVATE_KEY"]
                    .iter()
                    .any(|part| key.contains(part))
        })
        .map(|(_, value)| value)
        .collect();
    secrets.sort_by_key(|value| std::cmp::Reverse(value.len()));
    for secret in secrets {
        output = output.replace(&secret, "[REDACTED]");
    }
    output
        .lines()
        .map(|line| {
            let mut result = line.to_owned();
            let mut offset = 0;
            while let Some(index) = result[offset..].find(['=', ':']) {
                let delimiter = offset + index;
                let key_end = result[..delimiter]
                    .trim_end_matches([' ', '\t', '\"', '\''])
                    .len();
                let key_start = result[..key_end]
                    .char_indices()
                    .rfind(|(_, c)| !c.is_ascii_alphanumeric() && *c != '_')
                    .map_or(0, |(index, ch)| index + ch.len_utf8());
                let key = result[key_start..key_end].to_ascii_lowercase();
                offset = delimiter + 1;
                if ["token", "secret", "password", "api_key", "private_key"]
                    .iter()
                    .any(|part| key.contains(part))
                {
                    let start = offset + result[offset..].len()
                        - result[offset..].trim_start_matches([' ', '\t']).len();
                    let quote = result[start..]
                        .chars()
                        .next()
                        .filter(|c| *c == '\"' || *c == '\'');
                    let start = start + usize::from(quote.is_some());
                    let end = result[start..]
                        .find(|c: char| match quote {
                            Some(quote) => c == quote,
                            None => c.is_whitespace() || matches!(c, ',' | ';' | '\"' | '\'' | '}'),
                        })
                        .map_or(result.len(), |len| start + len);
                    result.replace_range(start..end, "[REDACTED]");
                    offset = start + "[REDACTED]".len();
                }
            }
            let mut offset = 0;
            while let Some((index, _)) = result[offset..]
                .to_ascii_lowercase()
                .match_indices("bearer")
                .find(|(index, _)| result[offset + index + 6..].starts_with(char::is_whitespace))
            {
                let start = offset + index + 6;
                let start = start + result[start..].len() - result[start..].trim_start().len();
                let end = result[start..]
                    .find(|c: char| c.is_whitespace() || matches!(c, '\"' | '\'' | ',' | ';'))
                    .map_or(result.len(), |len| start + len);
                result.replace_range(start..end, "[REDACTED]");
                offset = start + "[REDACTED]".len();
            }
            for prefix in ["sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-"] {
                let mut offset = 0;
                while let Some(index) = result[offset..].find(prefix) {
                    let start = offset + index;
                    let end = result[start..]
                        .find(|c: char| !c.is_ascii_alphanumeric() && c != '_' && c != '-')
                        .map_or(result.len(), |len| start + len);
                    if end - start >= 16 {
                        result.replace_range(start..end, "[REDACTED]");
                        offset = start + "[REDACTED]".len();
                    } else {
                        offset = end;
                    }
                }
            }
            result
        })
        .collect::<Vec<_>>()
        .join("\n")
        + if input.ends_with('\n') { "\n" } else { "" }
}

pub fn command(args: &[String]) -> Result<()> {
    if !args.is_empty() {
        bail!("Usage: squad redact < input");
    }
    let mut input = String::new();
    std::io::stdin().read_to_string(&mut input)?;
    std::io::stdout().write_all(redact(&input).as_bytes())?;
    Ok(())
}
