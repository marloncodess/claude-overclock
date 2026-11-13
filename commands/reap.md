---
description: Find and end orphaned dev servers, test runs and headless browsers whose Claude session is gone
allowed-tools: Bash(powershell *), PowerShell
---

First list them without changing anything:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" reap
```

Show the user the trees that can be ended safely (older than 10 minutes, not background services) with their memory, and ask for a clear yes. Only after the user agrees, run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" reap -Kill -Yes
```
