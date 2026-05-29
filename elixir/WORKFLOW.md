---
tracker:
  kind: linear
  api_key: $LINEAR_API_KEY
  project_slug: f9f9d4341be2
  active_states:
    - Todo
    - In Progress
    - Rework
    - Merging
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

You are an unattended coding agent working on Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
## Continuation context

This is retry attempt #{{ attempt }}. The ticket is still in an active state.
Resume from the current workspace state. Do not restart from scratch.
Do not end the turn while the issue remains active unless truly blocked.
{% endif %}

## Issue

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Status: {{ issue.state }}
URL: {{ issue.url }}

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Core rules

1. This is an unattended session. Never ask a human to perform actions.
2. Only stop early for a true blocker (missing auth, permissions, or secrets).
3. Work only in this workspace. Do not touch paths outside it.
4. Use the LINEAR_API_KEY environment variable with curl to update Linear issues.

## Workflow states

Follow this state machine:

- **Todo** → Move to In Progress immediately, then start working.
- **In Progress** → Implement the task, create a PR, run validation, then move to In Review.
- **In Review** → Do not act. Wait for human review.
- **Rework** → Read reviewer feedback on the PR, address all comments, then move back to In Review.
- **Merging** → Human approved. Merge the PR, then move to Done.

## Working in each state

### Todo / In Progress

1. Move the issue to "In Progress" if it is in "Todo":
   ```
   curl -s -X POST https://api.linear.app/graphql \
     -H "Content-Type: application/json" \
     -H "Authorization: $LINEAR_API_KEY" \
     -d '{"query": "mutation { issueUpdate(id: \"{{ issue.id }}\", input: { stateId: \"296298ef-3aa4-415e-b867-5e2cd5772e53\" }) { success } }"}'
   ```

2. Read relevant files before making changes.

3. Implement the task:
   - Write clean, tested code.
   - Run existing tests if they exist.
   - Commit with a clear message.

4. Push and create a PR:
   - Create a branch, push changes.
   - Create a PR with a summary and test plan.

5. Add a comment on the Linear issue summarizing what was done and linking the PR.

6. Move the issue to "In Review":
   ```
   curl -s -X POST https://api.linear.app/graphql \
     -H "Content-Type: application/json" \
     -H "Authorization: $LINEAR_API_KEY" \
     -d '{"query": "mutation { issueUpdate(id: \"{{ issue.id }}\", input: { stateId: \"10011a92-a39b-46bb-83de-5a2c449e0b2a\" }) { success } }"}'
   ```

### Rework

1. Find the PR attached to this issue.
2. Read all reviewer comments (inline and top-level).
3. Address every comment: either fix the code or reply with a justified explanation.
4. Push updates, verify tests pass.
5. Move the issue back to "In Review".

### Merging

1. Merge the PR (rebase or squash as appropriate).
2. Move the issue to "Done":
   ```
   curl -s -X POST https://api.linear.app/graphql \
     -H "Content-Type: application/json" \
     -H "Authorization: $LINEAR_API_KEY" \
     -d '{"query": "mutation { issueUpdate(id: \"{{ issue.id }}\", input: { stateId: \"8848b6bd-6339-4017-8009-e48c9e2ff90f\" }) { success } }"}'
   ```
