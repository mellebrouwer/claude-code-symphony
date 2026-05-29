---
name: symphony
description: Manage Symphony CC instances — the automated coding agent backed by Linear + Claude Code. Use when the user mentions "symphony", "symphony setup", "start symphony", "stop symphony", "symphony status", or wants to set up automated agents for a project, check running agent instances, or manage Linear-backed coding workflows.
argument-hint: "[setup <project>|start <project>|stop <project>|status|rebuild]"
allowed-tools: Bash
---

# Symphony CC Manager

Manage Symphony CC instances across projects. Each project gets its own Linear project, WORKFLOW.md, and launchd-managed process.

## Shared infrastructure

- **Binary:** `~/.local/bin/symphony` (escript — rebuild from `~/Documents/Coding/symphony-cc/elixir`)
- **OAuth credentials:** `~/.symphony/.linear_oauth.json` (shared across all instances)
- **Linear team ID:** `89e76573-6ebc-4fcd-90c9-0d4d2693bddd`
- **Launchd plists:** `~/Library/LaunchAgents/com.symphony-cc.<project>.plist`
- **WORKFLOW.md template:** `$SKILL_DIR/assets/WORKFLOW.template.md`
- **Scripts:** `$SKILL_DIR/scripts/`

## Commands

### `symphony status`

Run the status script — one call, clean output:

```bash
$SKILL_DIR/scripts/status.sh
```

Report the output directly to the user.

### `symphony start <project>`

```bash
launchctl load ~/Library/LaunchAgents/com.symphony-cc.<project>.plist && launchctl start com.symphony-cc.<project> && launchctl list | grep com.symphony-cc.<project>
```

### `symphony stop <project>`

```bash
launchctl stop com.symphony-cc.<project> && launchctl unload ~/Library/LaunchAgents/com.symphony-cc.<project>.plist
```

### `symphony setup <project>`

Full setup for a new project. Requires the project's repo path (local) and GitHub URL.

1. **Create Linear project** using Mell's personal API key (OAuth app may lack project-create permissions):
   ```bash
   LINEAR_KEY=$(credentials get op://Linear\ API/credential)
   curl -s -X POST https://api.linear.app/graphql \
     -H "Content-Type: application/json" \
     -H "Authorization: $LINEAR_KEY" \
     -d '{"query": "mutation { projectCreate(input: { name: \"<Project Name>\", teamIds: [\"89e76573-6ebc-4fcd-90c9-0d4d2693bddd\"] }) { success project { id slugId } } }"}'
   ```
   Save the `slugId` from the response.

2. **Copy and customize WORKFLOW.md:**
   - Copy `$SKILL_DIR/assets/WORKFLOW.template.md` to `<project-root>/WORKFLOW.md`
   - Replace `{{PROJECT_SLUG}}`, `{{PROJECT_NAME}}`, `{{REPO_PATH}}`, `{{GITHUB_URL}}`
   - Ask Mell if she wants to customize the agent prompt for this project

3. **Create launchd plist** at `~/Library/LaunchAgents/com.symphony-cc.<project>.plist`:
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
   <plist version="1.0">
   <dict>
     <key>Label</key>
     <string>com.symphony-cc.<project></string>
     <key>ProgramArguments</key>
     <array>
       <string>/Users/mellbrouwer/.local/bin/symphony</string>
       <string><path-to-WORKFLOW.md></string>
       <string>--i-understand-that-this-will-be-running-without-the-usual-guardrails</string>
     </array>
     <key>WorkingDirectory</key>
     <string><project-root></string>
     <key>EnvironmentVariables</key>
     <dict>
       <key>PATH</key>
       <string>/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Users/mellbrouwer/.local/bin</string>
       <key>HOME</key>
       <string>/Users/mellbrouwer</string>
     </dict>
     <key>RunAtLoad</key>
     <false/>
     <key>KeepAlive</key>
     <false/>
     <key>StandardOutPath</key>
     <string>/Users/mellbrouwer/.symphony/logs/<project>.stdout.log</string>
     <key>StandardErrorPath</key>
     <string>/Users/mellbrouwer/.symphony/logs/<project>.stderr.log</string>
   </dict>
   </plist>
   ```
   Create log directory: `mkdir -p ~/.symphony/logs`

4. **Report** the setup to Mell — don't start it automatically.

### `symphony rebuild`

```bash
cd ~/Documents/Coding/symphony-cc/elixir && mix build && cp bin/symphony ~/.local/bin/symphony
```

Then restart any running instances (stop + start each).

## Important notes

- **Never start Symphony without Mell's go-ahead** on `setup`.
- **KeepAlive is false by default.** Set to `<true/>` in the plist and reload if Mell wants auto-restart for a project.
- **Logs** at `~/.symphony/logs/<project>.{stdout,stderr}.log`.
- **One binary, many configs.** Rebuild once, restart instances to pick up changes.
