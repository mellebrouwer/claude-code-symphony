#!/usr/bin/env python3
"""Symphony CC watchdog — sets each Linear project's health from launchd liveness.

No project map is stored anywhere. The link already exists and is read live:

    com.symphony-cc.<project>.plist  --(ProgramArguments)-->  WORKFLOW.md
    WORKFLOW.md                      --(project_slug:)----->  Linear project

So adding/removing/renaming a project needs no change here — the plist and its
WORKFLOW.md are the single source of truth and cannot drift from themselves.

A process cannot announce its own death, so health is owned by this external
watchdog (woken on a schedule by com.symphony-cc.watchdog.plist), never by
Symphony itself:

    launchd job running  -> onTrack
    launchd job stopped  -> offTrack

It posts a Linear project update only when health actually changes, to keep the
update feed quiet. HTTP goes through curl (system CA store; the stock macOS
python has no usable certs).
"""

import glob
import json
import os
import plistlib
import re
import subprocess
import sys
from datetime import datetime

OAUTH_FILE = os.path.expanduser("~/.symphony/.linear_oauth.json")
LAUNCH_AGENTS = os.path.expanduser("~/Library/LaunchAgents")
PLIST_GLOB = os.path.join(LAUNCH_AGENTS, "com.symphony-cc.*.plist")
SELF_LABEL = "com.symphony-cc.watchdog"
GRAPHQL = "https://api.linear.app/graphql"
TOKEN_URL = "https://api.linear.app/oauth/token"


def log(msg):
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


def curl_json(url, *args):
    """POST via curl, return parsed JSON (or None on failure)."""
    out = subprocess.run(
        ["curl", "-s", "-X", "POST", url, *args],
        capture_output=True, text=True, timeout=30,
    ).stdout
    try:
        return json.loads(out)
    except (json.JSONDecodeError, ValueError):
        log(f"non-JSON response from {url}: {out[:200]!r}")
        return None


def get_access_token():
    with open(OAUTH_FILE) as fh:
        creds = json.load(fh)
    resp = curl_json(
        TOKEN_URL,
        "-d", "grant_type=client_credentials",
        "-d", f"client_id={creds['client_id']}",
        "-d", f"client_secret={creds['client_secret']}",
        "-d", "actor=app",
        "-d", "scope=read,write",
    )
    return (resp or {}).get("access_token")


def gql(token, query, variables=None):
    payload = {"query": query, "variables": variables or {}}
    return curl_json(
        GRAPHQL,
        "-H", f"Authorization: {token}",
        "-H", "Content-Type: application/json",
        "-d", json.dumps(payload),
    )


def workflow_path_for(plist_file):
    """Pull the WORKFLOW.md path out of the plist's ProgramArguments."""
    with open(plist_file, "rb") as fh:
        data = plistlib.load(fh)
    for arg in data.get("ProgramArguments", []):
        if isinstance(arg, str) and arg.endswith(".md"):
            return arg
    return None


def project_slug_for(workflow_file):
    """Read tracker.project_slug from the WORKFLOW.md YAML frontmatter."""
    with open(workflow_file) as fh:
        lines = fh.readlines()
    # Frontmatter is the block between the first two '---' fences.
    fences = [i for i, ln in enumerate(lines) if ln.strip() == "---"]
    end = fences[1] if len(fences) >= 2 else len(lines)
    for line in lines[:end]:
        m = re.match(r"\s*project_slug:\s*(\S+)", line)
        if m:
            return m.group(1)
    return None


def is_running(label):
    """True iff launchd reports a live PID for the job."""
    res = subprocess.run(
        ["launchctl", "list", label], capture_output=True, text=True
    )
    if res.returncode != 0:
        return False  # not loaded
    return re.search(r'"PID"\s*=\s*\d+', res.stdout) is not None


def current_health(token, slug):
    """Return (project_uuid, health) for a slugId, or (None, None)."""
    resp = gql(token, "query($id:String!){ project(id:$id){ id health } }", {"id": slug})
    proj = ((resp or {}).get("data") or {}).get("project")
    if not proj:
        return None, None
    return proj.get("id"), proj.get("health")


def post_health(token, project_uuid, health, body):
    resp = gql(
        token,
        "mutation($p:String!,$h:ProjectUpdateHealthType,$b:String!){"
        " projectUpdateCreate(input:{projectId:$p,health:$h,body:$b}){ success } }",
        {"p": project_uuid, "h": health, "b": body},
    )
    return bool((((resp or {}).get("data") or {}).get("projectUpdateCreate") or {}).get("success"))


def main():
    token = get_access_token()
    if not token:
        log("OAuth exchange failed — aborting")
        return 1

    ts = datetime.now().astimezone().strftime("%Y-%m-%d %H:%M %Z")
    plists = sorted(glob.glob(PLIST_GLOB))
    if not plists:
        log("no Symphony instances configured")
        return 0

    for plist_file in plists:
        label = os.path.basename(plist_file)[: -len(".plist")]
        if label == SELF_LABEL:
            continue
        short = label[len("com.symphony-cc."):]

        workflow = workflow_path_for(plist_file)
        if not workflow or not os.path.isfile(workflow):
            log(f"{short}: WORKFLOW.md not found ({workflow}) — skip")
            continue
        slug = project_slug_for(workflow)
        if not slug:
            log(f"{short}: no project_slug in {workflow} — skip")
            continue

        desired = "onTrack" if is_running(label) else "offTrack"
        project_uuid, health = current_health(token, slug)
        if not project_uuid:
            log(f"{short} ({slug}): project lookup failed — skip")
            continue
        if health == desired:
            log(f"{short} ({slug}): already {desired} — no update")
            continue

        if desired == "onTrack":
            body = f"✅ Symphony is running — checked {ts}."
        else:
            body = f"🔴 Symphony is not running — detected {ts}. The launchd job is stopped or unloaded."
        ok = post_health(token, project_uuid, desired, body)
        log(f"{short} ({slug}): {health} -> {desired} (posted={ok})")

    return 0


if __name__ == "__main__":
    sys.exit(main())
