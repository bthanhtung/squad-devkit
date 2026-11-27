use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Serialize, PartialEq)]
pub struct Event {
    pub schema_version: u8,
    pub timestamp: Option<String>,
    pub engine: String,
    pub model: Option<String>,
    pub event: String,
    pub tokens_in: Option<u64>,
    pub tokens_cached: Option<u64>,
    pub tokens_out: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub status: Option<String>,
}

pub fn normalize(engine: &str, input: &str) -> Vec<Event> {
    let mut events = Vec::new();
    for line in input.lines() {
        let Ok(v) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let kind = v
            .get("type")
            .or_else(|| v.get("event"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let event = match (engine, kind) {
            ("claude", "assistant")
            | ("codex", "turn.started")
            | ("opencode", "step-start")
            | ("ccr", "assistant") => "turn",
            ("claude", "tool_use")
            | ("codex", "item.started")
            | ("opencode", "tool")
            | ("ccr", "tool_use") => "tool_call",
            ("claude", "result")
            | ("codex", "token_count")
            | ("opencode", "step-finish")
            | ("ccr", "result") => "result",
            (_, "usage") => "usage",
            (_, "error") | (_, "turn.failed") => "error",
            _ => continue,
        };
        let usage = v
            .get("usage")
            .or_else(|| v.pointer("/message/usage"))
            .unwrap_or(&Value::Null);
        let number = |keys: &[&str]| {
            keys.iter()
                .find_map(|k| usage.get(*k).or_else(|| v.get(*k)).and_then(Value::as_u64))
        };
        let model = v
            .get("model")
            .and_then(Value::as_str)
            .or_else(|| v.pointer("/message/model").and_then(Value::as_str))
            .map(str::to_owned);
        events.push(Event {
            schema_version: 1,
            timestamp: v
                .get("timestamp")
                .or_else(|| v.get("created_at"))
                .and_then(Value::as_str)
                .map(str::to_owned),
            engine: engine.to_owned(),
            model,
            event: event.to_owned(),
            tokens_in: number(&["input_tokens", "tokens_in", "prompt_tokens"]),
            tokens_cached: number(&["cache_read_input_tokens", "cached_tokens", "tokens_cached"]),
            tokens_out: number(&["output_tokens", "tokens_out", "completion_tokens"]),
            exit_code: v.get("exit_code").and_then(Value::as_i64).map(|n| n as i32),
            status: v.get("status").and_then(Value::as_str).map(str::to_owned),
        });
    }
    events
}
