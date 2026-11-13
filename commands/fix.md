---
description: Repair what the disk doctor found: schedule the file system repair, turn maintenance back on, rebuild performance counters, run TRIM
allowed-tools: Bash(powershell *), PowerShell
---

First show what would be done:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" disk repair -DryRun
```

Show the user the planned steps and ask for a clear yes. These steps change Windows settings and need an elevated (administrator) shell. Only after the user agrees, run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" disk repair -Yes
```

If it says it needs an elevated PowerShell, give the user that exact command to run in a PowerShell opened with "Run as administrator". Remind them that the file system repair runs at the next restart, and that TRIM runs only after that repair (run /overclock:fix again after the restart).
