---
name: overclock
description: Use when the user's Windows PC is slow, hot or stuck at 100 % CPU, 100 % disk or full RAM, when Task Manager shows hundreds of thousands or millions of handles, when many Claude Code sessions, agents, workflows, dev servers or tests run at once, or when the user asks what is eating their CPU, RAM or disk.
---

# claude-overclock

`overclock.ps1` (Windows PowerShell 5.1, no dependencies) measures the machine and names the Claude session, agent, process or driver responsible.

Run it with:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" <command>
```

## Start here

1. `check` (about 20 s, read-only): CPU, RAM, disk I/O and handles grouped by owner, plus findings with the fix for each.
2. Follow the findings:
   - CPU or RAM taken by many sessions or agents: `sessions`, `agents`; free the machine without stopping work with `throttle`.
   - Disk at 100 %, file system errors, no TRIM: `disk`, then `disk repair -DryRun`.
   - Handles growing: `leaks`, then `handles <process>`.
   - Left-over dev servers and test runs: `reap` (lists), `reap -Kill -Yes` (ends).
   - Many short processes: `spawns` (admin).

## Rules

- Read-only: `check`, `disk`, `sessions`, `agents`, `leaks`, `handles`, `spawns`, `reap` without `-Kill`, `watchdog status`, `report`, `disk repair -DryRun`.
- Ask the user for a clear yes before: `reap -Kill -Yes`, `throttle`, `disk repair -Yes`, `watchdog install|remove`. Show what will change first.
- Never stop or archive the user's Claude sessions on your own; name the heavy ones and let the user decide.
- `disk repair`, `watchdog`, `spawns` and `handles` need an elevated PowerShell. If the shell is not elevated, give the user the exact command to run as administrator.
- RAM above 90 % on an SSD makes Windows page to disk; that alone can hold the disk at 100 %. Freeing RAM is often the real disk fix.
