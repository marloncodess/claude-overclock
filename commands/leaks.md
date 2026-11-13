---
description: Find processes whose handle count keeps growing (driver and service leaks)
argument-hint: [-Seconds 60]
allowed-tools: Bash(powershell *), PowerShell
---

Run (it samples for about a minute):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" leaks $ARGUMENTS
```

For every LEAK, explain the fix it prints. A watchdog is a stop-gap; offer /overclock:watchdog only if the user wants it.
