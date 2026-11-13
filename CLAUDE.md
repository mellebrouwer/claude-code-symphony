# claude-code-symphony

README.md is the upstream OpenAI Symphony readme; the Claude Code specifics are in skill/SKILL.md and below.

## Notes moved from Claude's memory

Mell's fork of OpenAI's Symphony (Elixir) with the Codex adapter replaced by Claude Code. Formerly named symphony-cc (launchd labels and paths still use `com.symphony-cc.*`). Origin remote is `mellebrouwer/claude-code-symphony` (not `openai/symphony`).

Why: Mell wants automated coding agents that pick up Linear tickets, do the work, and post results for human review. Flow: Todo -> In Progress -> In Review -> (human comments) -> auto-Rework -> In Review -> Merging -> Done -> auto-archived after 24h.

Key infrastructure:
- Binary installed at `~/.local/bin/symphony`; rebuild with `/symphony rebuild` after code changes.
- OAuth credentials at `~/.symphony/.linear_oauth.json` (shared across instances). OAuth app "Claude" with `actor=app`, so agent comments show as Claude, not Mell.
- Launchd plists at `~/Library/LaunchAgents/com.symphony-cc.*.plist`; logs at `~/.symphony/logs/`.
- Skill at `~/.claude/skills/symphony` (symlinked from the repo's `skill/` dir); `setup.sh` links it and builds the escript if missing.

Agent engine: the Claude Code adapter (`claude_code/adapter.ex`) drives agents through claude-code-server: one persistent interactive `claude` tmux session per agent over stdio JSON-RPC (`claude_code/app_server_client.ex` GenServer), replacing the old `claude -p --resume` per-turn spawn (context/caches persist across turns). Config under `claude_code:` in WORKFLOW.md: `app_server_path`, `python_bin`, `model`, `permission_mode`, `tmux_socket_prefix`; each agent gets a unique `<prefix>_<random>` tmux socket.

Dispatch auth: Linear auth is OAuth Bearer only (`Client.graphql_headers/0`); the vestigial `tracker.api_key` guard was removed from `fetch_candidate_issues`/`fetch_issues_by_states`/`Config.validate!` (it silently blocked all dispatch once `LINEAR_API_KEY` left the env). Agents still get `LINEAR_API_KEY=Bearer <oauth-token>` injected; that is the var the in-workspace agent uses to call Linear.

Known test debt: `mix test` is not green (about 43 failures in `app_server_test.exs`, `dynamic_tool_test.exs`, `core_test.exs`, `orchestrator_status_test.exs`, all `SymphonyElixir.Codex.AppServer is undefined`): an incomplete Codex-to-Claude test migration, unrelated to the engine. Needs a separate cleanup (delete or port the Codex tests).
