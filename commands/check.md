---
description: Health check: who uses CPU, RAM, disk and handles right now, and what to do about it
argument-hint: [-Seconds 20]
allowed-tools: Bash(powershell *), PowerShell
---

Run this command and wait for it to finish (about 20 seconds):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" check $ARGUMENTS
```

Show the user the findings, most severe first, in the user's language. For each HIGH finding, say in one sentence what it means and which overclock command fixes it. Do not run commands that change anything without asking.
