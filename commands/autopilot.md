---
description: Turn on automatic cleanup - every 10 min end orphaned Claude process trees and keep Claude sessions at below-normal priority
argument-hint: install | status | remove
allowed-tools: Bash(powershell *), PowerShell
---

The user typed this command, so do what the argument says without asking again. With no argument, use `status`.

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" autopilot $ARGUMENTS
```

- `install`: a scheduled task for the current user (no admin needed). Every 10 minutes it ends orphaned process trees older than 30 minutes that it saw inside a Claude session before (never the user's own programs), and sets new Claude sessions and everything they start to below-normal priority. Every action goes to a log.
- `status`: last run and the last actions.
- `remove`: turns it off.

Summarise the result in the user's language in two or three sentences.
