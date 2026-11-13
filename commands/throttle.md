---
description: Give your own apps priority: every Claude Code session and everything it started runs below normal priority, nothing is stopped
argument-hint: [-Undo]
allowed-tools: Bash(powershell *), PowerShell
---

Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" throttle $ARGUMENTS
```

Tell the user how many processes were changed, that builds, tests and agents keep running on the CPU time the user is not using, and that /overclock:throttle -Undo reverts it.
