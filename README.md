# claude-pc-doctor 🩺

**Is your Windows PC at 100 % CPU, RAM full, and Task Manager showing millions of handles while Claude Code runs?**
`pcdoctor` tells you which session, agent, process or driver is responsible, in one command.

![Task Manager: CPU 100 %, RAM 96 %, 921 processes, 2,224,585 handles](assets/taskmanager-2m-handles.png)

*My PC after 29 hours: CPU 100 %, RAM 96 %, disk 93 %, 921 processes and **2.2 million handles** (normal is 100-300k).*

## Quick start

Download `pcdoctor.ps1` and `known-issues.json` (or clone the repo) and run in PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\pcdoctor.ps1
```

It samples your PC for 20 seconds and prints:

```
== Who uses the CPU (20 s, 100 % = all 16 threads)
 11.9 %   101 proc  Claude session f868a144 ~\my-app [worktree] e2e-plan
  6.9 %     1 proc  vmmem
...
== Handles (growth over 20 s)
    63,690   +758,880/h  mtkbtsvc (MTKBTSVC)  <-- LEAK
...
== Findings
[HIGH] mtkbtsvc leaks handles: 63,690 now, about 758,880 more per hour.
       -> Update the Bluetooth driver ... Until then: pcdoctor watchdog install mtkbtsvc
[HIGH] Up to 14 agents ran at the same time in the last hour (workflows/subagents).
[WARN] 21 Claude Code sessions are running at the same time.
[WARN] MCP server "claude-mem" runs 22 times (once per session).
[WARN] 8 orphaned process trees (7.1 GB) from sessions that are gone.
       -> pcdoctor orphans -Kill
```

Run it as administrator for everything; `check`, `sessions`, `agents`, `leaks` and `orphans` also work without.

## Commands

| Command | What it does | Changes anything? |
|---|---|---|
| `check` | 20-second health check: CPU, RAM and handles **by owner** (each Claude session with everything it started), MCP copies, agents, orphans, leaks, watchdogs | no |
| `sessions` | every Claude Code session: model, project, processes, memory, MCP servers, dev servers with ports, tests, browsers, agents started by your own code | no |
| `agents -Hours 24` | agent activity from the session logs: subagents per hour, workflows, peak concurrency, which session started the most agents | no |
| `leaks` | 60-second handle sample, names every process whose handles keep growing, with the service it hosts | no |
| `handles <name\|pid>` | breaks one process's handles down by object type (Event, File, Process, ...) | no (admin) |
| `spawns` | counts every process start for 60 s and shows which session they come from | no (admin) |
| `orphans` | process trees whose session or shell is gone: dev servers, test runs, headless browsers, with ports | no |
| `orphans -Kill` | ends them, asks per tree, skips trees younger than 10 minutes and background services | yes |
| `watchdog install <process>` | scheduled task (SYSTEM) that restarts a leaking service above `-Threshold` handles, every `-Every` minutes | yes (admin) |
| `watchdog status` / `remove <process>` | shows last run of each watchdog and flags a deleted or stopped one | status: no |
| `report` | writes `pcdoctor-report.md` for an issue, without user names, paths or project names | no |

Everything is one PowerShell 5.1 file without dependencies. Windows 10 and 11.

## What actually took my PC down

I expected one bug. It was six things on top of each other. All numbers are from my PC (Ryzen 7 7800X3D, 32 GB, Windows 10 22H2), measured with the commands above.

### 1. A Bluetooth driver leaking Event handles (the 2 million handles)

`mtkbtsvc.exe`, the service of the **MediaTek RZ608** Wi-Fi/Bluetooth adapter (driver 1.1044.0.556), held **464,317 handles**, three quarters of all handles on the PC.

```
pcdoctor handles mtkbtsvc
== mtkbtsvc (pid 22444): 96,088 handles
    96,002   99.9 %  Event
```

- It grows in bursts: from 0 to **760,000 handles per hour**. After 29 hours of uptime the PC had 2.2 million handles.
- It has nothing to do with Claude Code: during 439 extra process starts it gained **0** handles.
- Restarting the service drops it to about 200 handles, until it starts again.

**Fix:** a newer Bluetooth driver. **Until then:** `pcdoctor watchdog install mtkbtsvc` restarts the service whenever it passes 100,000 handles (Bluetooth devices drop for a few seconds).

> My first watchdog task **disappeared shortly after I created it** (its task folder was last changed 50 seconds after the test run), and I only noticed a day later, when the handles were back at 2 million. That is why `watchdog status` writes a heartbeat on every run and reports `TASK MISSING` or `STALE`.

### 2. One workflow with 24 agents (the 100 % CPU)

A single session started a workflow at 03:02 with **8 agents at once**, 24 in total, each in its own copy of the repo. In 47 minutes they ran **1,120 shell commands**: Go tests and fuzzers, vitest, Docker, Python. That is where the `api.test.exe` and `chrome-headless-shell.exe` in Task Manager came from.

```
pcdoctor agents
== Subagents started per hour
13.11. 02:00     9  #############
13.11. 03:00    35  ##################################################
== Workflows
wf_0a238b36-ecd  done      24 agents  13.11. 03:02 - 03:49
wf_bc3cc6b7-7ed  RUNNING   22 agents  13.11. 03:56 - 04:17
```

I rebooted at 03:49. **The desktop app resumed all 21 open sessions, and the same session started the next 22-agent workflow 3 minutes after the PC was back up.** Rebooting does not help while the sessions stay open.

![Task Manager: Claude (254) at 47 % CPU and 6.7 GB](assets/taskmanager-claude-254.png)

### 3. 9,000 process starts per minute

```
pcdoctor spawns
== 3,026 process starts in 20 s = 9,078 per minute
  2,051  git.exe
    247  bash.exe
    154  conhost.exe
```

Tests that create throw-away git repos, plus every tool call (shell, `conhost`, every hook). Each start costs CPU and a scan by the anti-virus. If your RAM also disappears without an owner, a driver may keep these processes in kernel memory: see [claude-code-zombies](https://github.com/marloncodess/claude-code-zombies). That was not the problem this time (`zombieprobe`: 0 of 49).

### 4. Every session runs every MCP server

MCP servers from your user config start **once per session**. With 23 sessions and 3 servers that was 69 extra processes; the `claude-mem` copies alone used 4.8 GB. `check` flags any server that runs once per session, and `sessions` shows them per session.

### 5. A plugin hook on every tool call

`claude-mem` hooks into every `PostToolUse`, starts a process and queues an observation. At the peak its log grew by **2,526 lines in 10 minutes**, and it logged **6,583** times that it was rate-limited ("provider cooldown"), so the queue only grew. Its databases reached 2.6 GB + 1.6 GB. Hooks multiply with the number of agents.

### 6. Orphaned dev servers and test runs

Process trees whose session or shell no longer exists: duplicated `npm run dev` servers from hours ago, hanging `vitest run`, a Go fuzzer, `npm run pixel` with 4 headless Chromes. First cleanup: 7 trees, 60 processes, 26,000 handles. A day later: 8 new ones, **7.1 GB**.

**Not the cause** (tested): when Claude Code hits a command timeout it moves the command to the background instead of killing it, and stopping that background task ends the whole tree, also through `cmd`/`npx`. Where the orphans come from is still open. If you find out, please open an issue.

## What to do, in order

1. `pcdoctor` - read the findings.
2. **Archive sessions you don't use.** The desktop app resumes all of them after a restart, each with its own MCP servers.
3. **Cap parallel agents** in your workflows (e.g. 3-4). Each agent runs its own builds and tests.
4. `pcdoctor orphans -Kill` - end leftover dev servers and test runs.
5. Move MCP servers you need only in some projects from your user config into those projects' `.mcp.json`.
6. Check hooks in `~/.claude/settings.json` and plugin hooks: each one runs on every matching tool call.
7. `pcdoctor leaks` - if a process leaks handles, update its driver; `pcdoctor watchdog install <process>` bridges the time.
8. Cap WSL/Docker memory with `memory=8GB` in `%UserProfile%\.wslconfig`.

## Safety

- `check`, `sessions`, `agents`, `leaks`, `handles`, `spawns`, `orphans` and `report` only read.
- `orphans -Kill` asks before every tree and never touches trees younger than `-MinAgeMinutes` (default 10) or background services.
- `watchdog install` refuses a process that hosts several services (like `svchost`), because restarting it would restart all of them.
- `report` replaces your user name, PC name and paths, and calls projects `project-A`, `project-B`, ... It does list your MCP server names.

## Known issues

| Process | Device / driver | Version | Leak | Fix |
|---|---|---|---|---|
| `mtkbtsvc.exe` | MediaTek RZ608 Bluetooth | 1.1044.0.556 | Event handles, up to 760k/h | update the driver; `watchdog install mtkbtsvc` |

`check` and `leaks` look up [`known-issues.json`](known-issues.json). **Found a new one?** Run `pcdoctor report` and open an issue.

## Related

- [claude-code-zombies](https://github.com/marloncodess/claude-code-zombies): RAM fills up but no process owns it? A driver may keep every exited process in kernel memory. 30-second test and driver finder.

## License

MIT
