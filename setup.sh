#!/usr/bin/env bash
set -euo pipefail

# symphony-cc device setup — links the `symphony` skill into ~/.claude/skills
# and builds the `symphony` escript binary if it is missing.
# Idempotent. New device = git clone + ./setup.sh.
#
# Notes:
#   - The CLI is an Elixir escript (built with mix), not a Python tool, so uv
#     does not apply here. The watchdog (scripts/watchdog.py) runs on the stock
#     system python3 with no third-party deps (HTTP via curl) — nothing to install.
#   - This script never rebuilds an existing binary and never touches running
#     launchd instances. Use `symphony rebuild` (see SKILL.md) for deliberate rebuilds.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- link the skill into ~/.claude/skills ---
mkdir -p "$HOME/.claude/skills"
rm -rf "$HOME/.claude/skills/symphony"
ln -sfn "$REPO/skill" "$HOME/.claude/skills/symphony"
echo "✓ symphony skill -> $(readlink "$HOME/.claude/skills/symphony")"

# --- build the escript binary only if missing (don't disturb a built/running one) ---
BIN="$HOME/.local/bin/symphony"
if [ -x "$BIN" ]; then
  echo "✓ symphony binary already present at $BIN (not rebuilt — use 'symphony rebuild' to refresh)"
else
  if ! command -v mix >/dev/null 2>&1; then
    echo "✗ mix (Elixir) is required to build the symphony binary but was not found." >&2
    echo "  Install Elixir (e.g. brew install elixir) and re-run, or build manually:" >&2
    echo "    cd $REPO/elixir && mix build && cp bin/symphony $BIN" >&2
    exit 1
  fi
  echo "… building symphony escript (binary not found at $BIN) …"
  mkdir -p "$HOME/.local/bin"
  ( cd "$REPO/elixir" && mix build )
  cp "$REPO/elixir/bin/symphony" "$BIN"
  echo "✓ built and installed symphony -> $BIN"
fi

echo "Done. Verify: ~/.claude/skills/symphony/scripts/status.sh"
