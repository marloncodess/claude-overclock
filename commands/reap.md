---
description: End orphaned dev servers, test runs and headless browsers whose Claude session is gone (older than 10 minutes)
allowed-tools: Bash(powershell *), PowerShell
---

Run this right away, without asking first. It only ends trees whose session no longer exists, that are older than 10 minutes and that are not background services; younger ones are listed and left alone:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" reap -Kill -Yes
```

Tell the user in their language what was ended and how much memory that freed, and which younger trees were left running. If they want this to happen on its own from now on, mention /overclock:autopilot.
