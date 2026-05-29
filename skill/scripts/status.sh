#!/bin/bash
# Symphony CC status — lists all instances and their state

shopt -s nullglob
plists=(~/Library/LaunchAgents/com.symphony-cc.*.plist)

if [ ${#plists[@]} -eq 0 ]; then
  echo "No Symphony instances configured."
  exit 0
fi

printf "%-25s %-8s %-6s %s\n" "INSTANCE" "PID" "EXIT" "WORKFLOW"
printf "%-25s %-8s %-6s %s\n" "--------" "---" "----" "--------"

for plist in "${plists[@]}"; do
  label=$(basename "$plist" .plist)
  short=${label#com.symphony-cc.}
  info=$(launchctl list 2>/dev/null | grep "$label")
  if [ -n "$info" ]; then
    pid=$(echo "$info" | awk '{print $1}')
    exit_code=$(echo "$info" | awk '{print $2}')
    [ "$pid" = "-" ] && state="Stopped" || state="Running"
  else
    pid="-"
    exit_code="-"
    state="Unloaded"
  fi
  workflow=$(/usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$plist" 2>/dev/null)
  workflow=${workflow/#\/Users\/mellbrouwer/\~}
  printf "%-25s %-8s %-6s %s\n" "$short ($state)" "$pid" "$exit_code" "$workflow"
done

# Collect managed PIDs
managed_pids=""
for plist in "${plists[@]}"; do
  label=$(basename "$plist" .plist)
  p=$(launchctl list 2>/dev/null | grep "$label" | awk '{print $1}')
  [ "$p" != "-" ] && [ -n "$p" ] && managed_pids="$managed_pids $p"
done

# Check for orphans (symphony processes not in managed set)
while IFS= read -r line; do
  opid=$(echo "$line" | awk '{print $2}')
  managed=false
  for mp in $managed_pids; do
    [ "$opid" = "$mp" ] && managed=true && break
  done
  $managed || orphan_lines+=("$line")
done < <(ps aux | grep '[b]in/symphony')

if [ ${#orphan_lines[@]} -gt 0 ]; then
  echo ""
  echo "Warning: ${#orphan_lines[@]} orphan symphony process(es) not managed by launchd"
fi
