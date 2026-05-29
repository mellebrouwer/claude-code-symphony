# TODO

## Reap orphaned cc-appserver tmux/claude sessions

**Problem.** cc-appserver keeps each agent's tmux server + interactive `claude`
TUI *durable* — they outlive the Python manager (this is what enables
`resumeConversation` crash recovery). The adapter only tears them down via
`AppServerClient.terminate/2` (`tmux kill-server` + kill child), which OTP runs
on **graceful** shutdown only. So an abrupt Symphony death — `kill -9`, a BEAM
crash, OOM, or a `launchctl stop` that doesn't drain before launchd SIGKILLs it
— strands the in-flight agents' tmux servers + `claude` processes. There is no
reaper, so orphans **accumulate across restarts** (idle, so no token burn, but
RAM / process slots / operational clutter) until swept by hand.

Normal turn completion is fine: `AgentRunner`'s `try ... after stop_session`
reaps cleanly (verified end-to-end).

**Fix (cheap → robust):**

1. **Pass `--kill-sessions-on-exit`** to the `cc_appserver.py` child in
   `claude_code/app_server_client.ex` spawn args. On manager death the child
   gets stdin-EOF and its `amain` finally-block already calls
   `manager.shutdown()` → kills its own tmux sessions on the way out. Safe for
   the per-agent model (only fires when the child itself exits, so it doesn't
   touch the claude-died / python-lived `resumeConversation` path).

2. **Boot-time reaper.** On Symphony startup, `tmux -L` kill any pre-existing
   `<claude_code.tmux_socket_prefix>_*` servers. A fresh instance owns zero
   agents, so any such server is by definition an orphan from a prior instance.
   Catches the both-SIGKILLed case and stops accumulation cold.

3. *(Optional)* Trap SIGTERM for a graceful drain so `launchctl stop` runs
   `terminate/2`. Less urgent once 1 + 2 are in.
