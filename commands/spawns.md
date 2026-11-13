---
description: Count every process start for 60 seconds and show which session starts them (needs admin)
argument-hint: [-Seconds 60]
allowed-tools: Bash(powershell *), PowerShell
---

Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" spawns $ARGUMENTS
```

If it needs an elevated PowerShell, give the user the command to run as administrator.
