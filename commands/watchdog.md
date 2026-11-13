---
description: Install, check or remove a watchdog that restarts a handle-leaking service (e.g. install mtkbtsvc)
argument-hint: status | install <process> | remove <process>
allowed-tools: Bash(powershell *), PowerShell
---

If no argument was given, run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" watchdog status
```

For `install` or `remove`, explain what will happen (a scheduled task running as SYSTEM that restarts the service of that process when it passes 100,000 handles) and ask for a clear yes first. Then run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" watchdog $ARGUMENTS
```

It needs an elevated PowerShell; if it says so, give the user the command to run as administrator.
