---
description: Disk doctor: SSD health and temperature, file system errors, TRIM, maintenance, I/O by session, what fills the disk
argument-hint: [-NoSpace]
allowed-tools: Bash(powershell *), PowerShell
---

Run this command (it can take a minute while it measures folder sizes; add -NoSpace to skip that):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" disk $ARGUMENTS
```

Summarise the findings for the user in their language. If it reports file system errors, maintenance off, broken performance counters or missing TRIM, offer /overclock:fix.
