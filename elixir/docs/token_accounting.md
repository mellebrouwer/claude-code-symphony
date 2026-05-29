# Claude Code Token Accounting

This document explains how Claude Code reports token usage through its stream-json output and how Symphony accounts for it.

## Short Version

- Claude Code emits usage as a flat map with `input_tokens`, `output_tokens`, and optionally `cache_read_input_tokens`, `cache_creation_input_tokens`.
- Usage appears in two places: on each `assistant` event (in `message.usage`) and on the final `result` event (in `usage`).
- Symphony extracts tokens using a priority chain: Codex-style nested paths (legacy), then flat maps with integer token fields.
- The `result` event's usage is the authoritative total for the session.

## Claude Code Event Types

Claude Code with `--output-format stream-json` emits newline-delimited JSON events:

### `system/init`

Session initialization. Contains `session_id`, available tools, MCP servers. No usage data.

### `assistant`

Assistant response. Contains `message.usage`:

```json
{
  "type": "assistant",
  "message": {
    "usage": {
      "input_tokens": 1234,
      "output_tokens": 567,
      "cache_read_input_tokens": 31273,
      "cache_creation_input_tokens": 0
    }
  }
}
```

### `tool_use` / `tool_result`

Tool invocations and their results. No usage data.

### `result`

Final session result. Contains cumulative `usage`:

```json
{
  "type": "result",
  "subtype": "success",
  "session_id": "...",
  "usage": {
    "input_tokens": 1234,
    "output_tokens": 567,
    "cache_read_input_tokens": 31273,
    "cache_creation_input_tokens": 0
  },
  "total_cost_usd": 0.015
}
```

### `rate_limit_event`

Rate limit warnings. Contains `rate_limit_info` with status and reset time.

### `system/hook_*`

Hook lifecycle events (with `--verbose`). No usage data.

## How Symphony Extracts Tokens

The adapter (`ClaudeCode.Adapter`) extracts usage from `assistant` and `result` events and passes it to the orchestrator via the `:usage` metadata key.

The orchestrator's `extract_token_usage/1` searches for token data using this priority:

1. **Codex nested paths** (legacy) — `["params", "msg", "payload", "info", "total_token_usage"]` etc.
2. **Codex turn/completed** (legacy) — events with `method: "turn/completed"`
3. **Flat token maps** — any map containing integer-valued token fields (`input_tokens`, `output_tokens`, `total_tokens`, etc.)

For Claude Code, option 3 is what matches. The usage map from CC has string keys:

- `"input_tokens"` — prompt tokens
- `"output_tokens"` — completion tokens
- `"cache_read_input_tokens"` — cached prompt tokens read
- `"cache_creation_input_tokens"` — cached prompt tokens written

Note: CC does not emit a pre-computed `total_tokens`. The dashboard shows input and output separately.

## Accounting Strategy

Symphony uses high-water-mark accounting per running issue:

- Each update reports absolute token counts (not deltas)
- The orchestrator computes deltas by comparing against the last reported value
- This handles missed or reordered events gracefully
- Token counts reset when a new agent run starts for the same issue

## Key Differences From Codex

| Aspect | Codex | Claude Code |
|--------|-------|-------------|
| Protocol | JSON-RPC (`turn/completed`, `thread/tokenUsage/updated`) | JSONL stream (`assistant`, `result`) |
| Usage location | Deeply nested (`params.msg.payload.info.total_token_usage`) | Flat map (`message.usage` or top-level `usage`) |
| Total tokens | Pre-computed `total_tokens` field | Not present; sum `input_tokens + output_tokens` |
| Cache tokens | Not applicable | `cache_read_input_tokens`, `cache_creation_input_tokens` |
| Cost | Not reported | `total_cost_usd` on `result` event |
