---
description: Every running Claude Code session with its processes, memory, MCP servers, dev servers, tests and agents
allowed-tools: Bash(powershell *), PowerShell
---

Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" sessions
```

Point out the heaviest sessions, MCP servers that run once per session, and agents started by code or tests.
