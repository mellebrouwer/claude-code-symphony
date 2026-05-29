# Symphony CC

Fork of [OpenAI's Symphony](https://github.com/openai/symphony) with the Codex adapter replaced
by a Claude Code adapter. Uses Claude Code's `--output-format stream-json` protocol instead of the
Codex app-server JSON-RPC protocol.

> [!WARNING]
> Symphony CC is prototype software intended for evaluation only and is presented as-is.

## How it works

1. Polls Linear for candidate work
2. Creates a workspace per issue
3. Launches Claude Code in headless mode (`claude -p --output-format stream-json`) inside the
   workspace
4. Sends a workflow prompt to Claude Code
5. Keeps Claude Code working on the issue until the work is done

If a claimed issue moves to a terminal state (`Done`, `Closed`, `Cancelled`, or `Duplicate`),
Symphony stops the active agent for that issue and cleans up matching workspaces.

## How to use it

1. Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude` CLI).
2. Get a new personal token in Linear via Settings → Security & access → Personal API keys, and
   set it as the `LINEAR_API_KEY` environment variable.
3. Customize `WORKFLOW.md` for your project.
   - To get your project's slug, right-click the project and copy its URL. The slug is part of the
     URL.
4. Follow the instructions below to install the required runtime dependencies and start the service.

## Prerequisites

We recommend using [mise](https://mise.jdx.dev/) to manage Elixir/Erlang versions.

```bash
mise install
mise exec -- elixir --version
```

## Run

```bash
git clone https://github.com/openai/symphony
cd symphony/elixir
mise trust
mise install
mise exec -- mix setup
mise exec -- mix build
mise exec -- ./bin/symphony ./WORKFLOW.md
```

## Configuration

Pass a custom workflow file path to `./bin/symphony` when starting the service:

```bash
./bin/symphony /path/to/custom/WORKFLOW.md
```

If no path is passed, Symphony defaults to `./WORKFLOW.md`.

Optional flags:

- `--logs-root` tells Symphony to write logs under a different directory (default: `./log`)
- `--port` also starts the Phoenix observability service (default: disabled)

The `WORKFLOW.md` file uses YAML front matter for configuration, plus a Markdown body used as the
Claude Code session prompt.

Minimal example:

```md
---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: "..."
workspace:
  root: /tmp/symphony_workspaces
hooks:
  after_create: "git clone git@github.com:your-org/your-repo.git ."
agent:
  max_concurrent_agents: 3
  max_turns: 10
claude_code:
  command: claude
  turn_timeout_ms: 3600000
  stall_timeout_ms: 300000
---

You are a coding agent. Work on issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

Notes:

- If a value is missing, defaults are used.
- The workflow uses these Linear states: **Todo** → **In Progress** → **In Review** (human) →
  **Merging** → **Done**, with a **Rework** loop for reviewer feedback. Configure `active_states`
  to include all agent-driven states (not In Review — that's human-driven).
- `claude_code.command` specifies the Claude Code CLI binary (default: `claude`).
- `claude_code.turn_timeout_ms` is the maximum time for a single CC turn (default: 1 hour).
- `claude_code.stall_timeout_ms` is how long the orchestrator waits without events before
  considering an agent stalled and restarting it (default: 15 minutes). The adapter emits
  heartbeat events from non-JSON CC output (stderr, verbose logs) to keep the stall timer
  fresh while CC is actively running.
- `agent.max_turns` caps how many back-to-back Claude Code turns Symphony will run in a single
  agent invocation when a turn completes normally but the issue is still in an active state.
  Default: `20`.
- If the Markdown body is blank, Symphony uses a default prompt template that includes the issue
  identifier, title, and body.
- Use `hooks.after_create` to bootstrap a fresh workspace. For a Git-backed repo, you can run
  `git clone ... .` there.
- `tracker.api_key` reads from `LINEAR_API_KEY` when unset or when value is `$LINEAR_API_KEY`.
- For path values, `~` is expanded to the home directory.
- If `WORKFLOW.md` is missing or has invalid YAML at startup, Symphony does not boot.
- If a later reload fails, Symphony keeps running with the last known good workflow and logs the
  reload error until the file is fixed.
- `server.port` or CLI `--port` enables the optional Phoenix LiveView dashboard and JSON API at
  `/`, `/api/v1/state`, `/api/v1/<issue_identifier>`, and `/api/v1/refresh`.

## Web dashboard

The observability UI now runs on a minimal Phoenix stack:

- LiveView for the dashboard at `/`
- JSON API for operational debugging under `/api/v1/*`
- Bandit as the HTTP server
- Phoenix dependency static assets for the LiveView client bootstrap

## Project Layout

- `lib/`: application code and Mix tasks
- `test/`: ExUnit coverage for runtime behavior
- `WORKFLOW.md`: in-repo workflow contract used by local runs
- `../.codex/`: repository-local Codex skills and setup helpers

## Testing

```bash
make all
```

Run the Claude Code adapter test to verify the integration:

```bash
cd elixir
mix test test/symphony_elixir/claude_code_adapter_test.exs
```

This spawns a real Claude Code process, verifies JSONL event parsing, session ID extraction, and
turn completion.

## FAQ

### Why Elixir?

Elixir is built on Erlang/BEAM/OTP, which is great for supervising long-running processes. It has an
active ecosystem of tools and libraries. It also supports hot code reloading without stopping
actively running subagents, which is very useful during development.

### What's the easiest way to set this up for my own codebase?

Copy `WORKFLOW.md` to your repo and customize the project slug, hooks, and prompt.

## License

This project is licensed under the [Apache License 2.0](../LICENSE).
