---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: f9f9d4341be2
  active_states:
    - Todo
    - In Progress
  terminal_states:
    - Done
    - Canceled
    - Cancelled
    - Duplicate
claude_code:
  command: claude
  turn_timeout_ms: 3600000
  stall_timeout_ms: 900000
agent:
  max_concurrent_agents: 3
  max_turns: 10
workspace:
  root: /tmp/symphony_workspaces
hooks:
  after_create: "git clone /Users/mellbrouwer/Documents/Coding/symphony-cc . 2>/dev/null || true"
polling:
  interval_ms: 30000
---
You are a coding agent working on the symphony-cc repository (a fork of OpenAI's Symphony with a Claude Code adapter).

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}

Body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:
- Work in the repository checked out in this workspace.
- Read relevant files before making changes.
- Run tests if they exist.
- Commit your changes with a clear commit message when done.
- If you need to query Linear, use the LINEAR_API_KEY environment variable with curl.
