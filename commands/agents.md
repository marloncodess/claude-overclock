---
description: Agent activity from the session logs: subagents and workflows per hour, peak concurrency, top spawners
argument-hint: [-Hours 24]
allowed-tools: Bash(powershell *), PowerShell
---

Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" agents $ARGUMENTS
```

Summarise when most agents ran, the peak number of agents at once, and which session started them.
