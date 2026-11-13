---
description: Write overclock-report.md (no user names, paths or project names) to share in a GitHub issue
allowed-tools: Bash(powershell *), PowerShell
---

Run:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/overclock.ps1" report
```

Tell the user where the report was written and that it lists MCP server names, which they can remove before sharing at https://github.com/marloncodess/claude-overclock/issues/new
