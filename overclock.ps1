<#
.SYNOPSIS
  claude-overclock - finds out why your Windows PC hits 100 % CPU, full RAM, a busy disk or millions of
  handles while Claude Code (or any coding agent) runs, names the session, process or driver responsible,
  and fixes what can be fixed.

.DESCRIPTION
  Commands:
    check               (default) 20-second health check: CPU, RAM, disk I/O and handles by owner, Claude
                        sessions, MCP servers, agents, orphans, leaks, disk errors. Read-only.
    disk                SSD health and temperature, file system errors, TRIM, maintenance, I/O by owner and
                        what fills the disk (caches, worktrees, Docker). Read-only. -NoSpace skips the sizes.
    disk repair         fixes what 'disk' found: schedules the file system repair, turns maintenance back on,
                        rebuilds broken performance counters, runs TRIM. Asks before each step. Admin.
                        -DryRun only shows the steps.
    throttle            gives your own apps priority: every Claude Code session and everything it started
                        (builds, tests, agents, browsers) runs at below-normal priority. Nothing is stopped; new
                        processes inherit it. -Undo sets them back to normal.
    autopilot install   scheduled task for your user (no admin needed): every 10 min (-Every) it ends orphaned
                        trees older than 30 min (-MinAgeMinutes) that it saw inside a Claude session before,
                        and keeps Claude sessions at below-normal priority. Logs every action.
    autopilot status    last run and what it did.   autopilot remove   turns it off.
    sessions            every Claude Code session with its child processes, MCP servers and memory.
    agents              agent activity from the session logs: subagents and workflows per hour, peak concurrency.
    leaks               samples handle counts for 60 s and names every process whose handles keep growing.
    handles <name|pid>  breaks one process's handles down by object type. Admin.
    spawns              counts every process start for 60 s and shows which session starts them. Admin.
    orphans | reap      process trees whose session is gone (dev servers, test runs, headless browsers).
                        Add -Kill to end them (asks per tree, skips trees younger than -MinAgeMinutes).
    watchdog install <process>   restarts a leaking service once it holds -Threshold handles. Admin.
    watchdog status              lists every watchdog and when it last ran.
    watchdog remove <process>    removes a watchdog.
    report              writes overclock-report.md without user names, paths or project names.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\overclock.ps1
  powershell -ExecutionPolicy Bypass -File .\overclock.ps1 orphans -Kill
  powershell -ExecutionPolicy Bypass -File .\overclock.ps1 watchdog install mtkbtsvc -Threshold 100000
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('check', 'disk', 'throttle', 'autopilot', 'sessions', 'agents', 'leaks', 'handles', 'spawns', 'orphans', 'reap', 'watchdog', 'report', 'help')][string]$Command = 'check',
    [Parameter(Position = 1)][string]$Target = '',
    [Parameter(Position = 2)][string]$Name = '',
    [int]$Seconds = 0,
    [int]$Hours = 24,
    [int]$Threshold = 100000,
    [int]$Every = 5,
    [int]$MinAgeMinutes = 10,
    [string]$Service = '',
    [switch]$Kill,
    [switch]$Yes,
    [switch]$DryRun,
    [switch]$NoSpace,
    [switch]$Undo
)
$ErrorActionPreference = 'Stop'
$MinAgeBound = $PSBoundParameters.ContainsKey('MinAgeMinutes')
$EveryBound = $PSBoundParameters.ContainsKey('Every')
$Version = '0.3.3'
$RepoUrl = 'https://github.com/marloncodess/claude-overclock'
$ZombieRepo = 'https://github.com/marloncodess/claude-code-zombies'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$StateDir = Join-Path $env:ProgramData 'claude-overclock'
$TaskPath = '\claude-overclock\'
$ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$Cores = [Environment]::ProcessorCount

# ---------------------------------------------------------------- native helpers (handle types)
if (-not ('Overclock.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices;
namespace Overclock {
public class TypeInfo { public int Index; public string Name; public long Objects; public long Handles; }
public static class Native {
  [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
  [DllImport("ntdll.dll")] static extern int NtQueryObject(IntPtr h, int cls, IntPtr buf, int len, out int ret);
  [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr h, int cls, ref int info, int len);
  [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref int info, int len, out int ret);
  [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  const int TooSmall = unchecked((int)0xC0000004);

  // I/O priority of another process: 0 very low, 1 low (background), 2 normal. Returns the previous value, -1 on failure.
  public static int SetIoPriority(int pid, int want, int onlyIf) {
    IntPtr h = OpenProcess(0x0400 | 0x0200, false, pid);
    if (h == IntPtr.Zero) return -1;
    try {
      int cur = 0, ret;
      if (NtQueryInformationProcess(h, 33, ref cur, 4, out ret) != 0) return -1;
      if (onlyIf >= 0 && cur != onlyIf) return cur;
      int v = want;
      return NtSetInformationProcess(h, 33, ref v, 4) == 0 ? cur : -1;
    } finally { CloseHandle(h); }
  }

  public static TypeInfo[] Types() {
    var res = new List<TypeInfo>();
    if (IntPtr.Size != 8) return res.ToArray();
    int size = 64 * 1024, ret, st; IntPtr buf = IntPtr.Zero;
    try {
      while (true) {
        buf = Marshal.AllocHGlobal(size);
        st = NtQueryObject(IntPtr.Zero, 3, buf, size, out ret);
        if (st == TooSmall) { Marshal.FreeHGlobal(buf); buf = IntPtr.Zero; size = Math.Max(size * 2, ret + 4096); continue; }
        break;
      }
      if (st != 0) return res.ToArray();
      int n = Marshal.ReadInt32(buf, 0);
      long off = 8;
      for (int i = 0; i < n; i++) {
        IntPtr e = new IntPtr(buf.ToInt64() + off);
        int len = (ushort)Marshal.ReadInt16(e, 0), max = (ushort)Marshal.ReadInt16(e, 2);
        IntPtr name = Marshal.ReadIntPtr(e, 8);
        int idx = Marshal.ReadByte(e, 0x5A);
        res.Add(new TypeInfo { Index = idx == 0 ? i + 2 : idx, Name = Marshal.PtrToStringUni(name, len / 2),
          Objects = (uint)Marshal.ReadInt32(e, 0x10), Handles = (uint)Marshal.ReadInt32(e, 0x14) });
        off += 0x68 + max; off = (off + 7) & ~7L;
      }
    } catch { }
    finally { if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf); }
    return res.ToArray();
  }

  // object type index -> handle count, for one process
  public static Dictionary<int, int> HandleTypes(int pid) {
    var res = new Dictionary<int, int>();
    if (IntPtr.Size != 8) return res;
    int size = 16 * 1024 * 1024, ret, st; IntPtr buf = IntPtr.Zero;
    try {
      while (true) {
        buf = Marshal.AllocHGlobal(size);
        st = NtQuerySystemInformation(64, buf, size, out ret);
        if (st == TooSmall) { Marshal.FreeHGlobal(buf); buf = IntPtr.Zero; size = Math.Max(size * 2, ret + 4 * 1024 * 1024); continue; }
        break;
      }
      if (st != 0) return res;
      long n = Marshal.ReadInt64(buf, 0);
      for (long i = 0; i < n; i++) {
        long o = 16 + i * 40;
        if (Marshal.ReadInt64(new IntPtr(buf.ToInt64() + o + 8)) != pid) continue;
        int t = (ushort)Marshal.ReadInt16(new IntPtr(buf.ToInt64() + o + 30));
        int c; res.TryGetValue(t, out c); res[t] = c + 1;
      }
    } finally { if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf); }
    return res;
  }
}
}
'@
}

# ---------------------------------------------------------------- small utilities
function Write-Head([string]$t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }
function Write-Good([string]$t) { Write-Host $t -ForegroundColor Green }
function Write-Bad([string]$t) { Write-Host $t -ForegroundColor Red }
function Write-Warn2([string]$t) { Write-Host $t -ForegroundColor Yellow }
function Test-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Assert-Admin { if (-not (Test-Admin)) { Write-Bad 'This command needs an elevated PowerShell (Run as administrator).'; exit 2 } }
function Confirm-Step([string]$question) {
    if ($Yes) { return $true }
    $a = Read-Host "$question [y/N]"
    return ($a -match '^(y|yes|j|ja)$')
}
function Format-MB([double]$mb) { if ($mb -ge 1024) { '{0:N1} GB' -f ($mb / 1024) } else { '{0:N0} MB' -f $mb } }
function Format-Age([datetime]$t) {
    $s = (Get-Date) - $t
    if ($s.TotalHours -ge 24) { '{0:N0}d {1}h' -f [math]::Floor($s.TotalDays), $s.Hours } elseif ($s.TotalMinutes -ge 60) { '{0}h {1:00}m' -f [math]::Floor($s.TotalHours), $s.Minutes } else { '{0}m' -f [math]::Floor($s.TotalMinutes) }
}
function Limit-Text([string]$t, [int]$n) { $t = ($t -replace '\s+', ' ').Trim(); if ($t.Length -gt $n) { $t.Substring(0, $n - 3) + '...' } else { $t } }
function Hide-Paths([string]$t) {
    if (-not $t) { return $t }
    $t = $t.Replace($env:USERPROFILE, '~').Replace(($env:USERPROFILE -replace '\\', '/'), '~')
    $t = $t -replace [regex]::Escape("\Users\$env:USERNAME"), '\Users\<user>' -replace [regex]::Escape("/Users/$env:USERNAME"), '/Users/<user>'
    $t -replace [regex]::Escape($env:COMPUTERNAME), '<pc>'
}
function Get-KnownIssues {
    $f = Join-Path $ScriptDir 'known-issues.json'
    if (Test-Path $f) { (Get-Content $f -Raw | ConvertFrom-Json).handleLeaks } else { @() }
}

$KernelNames = @('System', 'Idle', 'Registry', 'Memory Compression', 'Secure System', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass')
$ApDir = Join-Path $env:LOCALAPPDATA 'claude-overclock'
# language servers that LSP plugins start once per session; Claude Code starts them again when it needs them
$LspPattern = 'typescript-language-server|pyright-langserver|basedpyright-langserver|[\\/ "]gopls(\.exe)?[" ]|rust-analyzer|vscode-[\w-]+-language-server|intelephense|jdtls|clangd'
$ShellNames = @('bash.exe', 'sh.exe', 'zsh.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe', 'conhost.exe', 'OpenConsole.exe')
$WatchNames = @('node.exe', 'bun.exe', 'deno.exe', 'bash.exe', 'sh.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe', 'python.exe', 'python3.exe', 'py.exe', 'uv.exe', 'uvx.exe', 'go.exe', 'esbuild.exe', 'chrome-headless-shell.exe', 'chrome.exe', 'msedge.exe', 'java.exe', 'cargo.exe', 'ruby.exe', 'dotnet.exe', 'docker.exe')

# ---------------------------------------------------------------- process snapshot and classification
function Get-Snap {
    $gp = @{}; foreach ($g in Get-Process) { $gp[$g.Id] = $g }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in Get-CimInstance Win32_Process) {
        $id = [int]$p.ProcessId; $cpu = 0.0
        if ($gp.ContainsKey($id)) { try { $cpu = [double]$gp[$id].CPU } catch { } }
        $created = if ($p.CreationDate) { $p.CreationDate } else { [datetime]::MinValue }
        $list.Add([pscustomobject]@{
                Id = $id; PPid = [int]$p.ParentProcessId; Name = [string]$p.Name; Created = $created
                Handles = [int]$p.HandleCount; Threads = [int]$p.ThreadCount; PrivMB = [math]::Round($p.PrivatePageCount / 1MB, 1)
                Cpu = $cpu; Cmd = [string]$p.CommandLine; Path = [string]$p.ExecutablePath
                Kind = ''; Role = ''; SessionId = ''; Model = ''; Project = ''; Cli = 0; TopCli = 0; InApp = $false
            })
    }
    $byId = @{}; foreach ($x in $list) { $byId[$x.Id] = $x }
    $kids = @{}
    foreach ($x in $list) {
        $p = $byId[$x.PPid]
        if ($p -and $p.Id -ne $x.Id -and $p.Created -le $x.Created) {
            if (-not $kids.ContainsKey($p.Id)) { $kids[$p.Id] = New-Object System.Collections.Generic.List[object] }
            $kids[$p.Id].Add($x)
        }
    }
    $s = [pscustomobject]@{ List = $list; ById = $byId; Kids = $kids; Taken = Get-Date }
    foreach ($x in $list) { $x.Kind = Get-Kind $x }
    foreach ($x in $list | Where-Object { $_.Kind -eq 'cli' }) {
        if ($x.Cmd -match '--(?:resume|session-id)[= ]"?([0-9a-f]{8}-[0-9a-f-]{27})') { $x.SessionId = $matches[1] }
        if ($x.Cmd -match '--model[= ]"?([\w.:-]+)') { $x.Model = $matches[1] }
    }
    foreach ($x in $list) {
        $c = Get-ValidParent $s $x; $depth = 0
        if ($x.Kind -eq 'app' -or $x.Kind -eq 'app-helper') { $x.InApp = $true }
        while ($c -and $depth -lt 60) {
            if ($c.Kind -eq 'cli') { if (-not $x.Cli) { $x.Cli = $c.Id }; $x.TopCli = $c.Id }
            if ($c.Kind -eq 'app') { $x.InApp = $true }
            $c = Get-ValidParent $s $c; $depth++
        }
    }
    foreach ($x in $list) { $x.Role = Get-Role $s $x }
    Set-Projects $s
    $s
}
function Get-ValidParent($s, $x) {
    $p = $s.ById[$x.PPid]
    if ($p -and $p.Id -ne $x.Id -and $p.Created -le $x.Created) { $p } else { $null }
}
function Get-Kind($x) {
    $n = $x.Name.ToLowerInvariant(); $c = $x.Cmd; $path = $x.Path
    if ($n -eq 'claude.exe') {
        if ($path -match '\\AnthropicClaude\\|\\WindowsApps\\Claude|\\Programs\\claude\\' -and $c -notmatch 'stream-json|--session-id|--resume|--print') {
            if ($c -match '--type=') { return 'app-helper' } else { return 'app' }
        }
        return 'cli'
    }
    if ($n -eq 'node.exe' -and $c -match '@anthropic-ai[\\/]claude-code[\\/]') { return 'cli' }
    ''
}
function Get-Label($x) {
    $c = $x.Cmd
    if ($c -match 'claude-mem') { return 'claude-mem' }
    if ($c -match 'node_modules[\\/](@[\w.-]+[\\/][\w.-]+)') { return $matches[1] }
    if ($c -match '(?:npx|bunx|uvx|pnpm dlx)(?:\.cmd)?"?\s+(?:-y\s+|--yes\s+)?(@?[\w.@/-]+)') { return $matches[1] }
    if ($c -match 'node_modules[\\/]([\w.-]+)') { return $matches[1] }
    if ($c -match '([\w.-]+)[\\/](?:dist|build|out|lib|bin|src|scripts|server)[\\/][\w.-]+\.(?:m?js|cjs|ts|py)') { return $matches[1] }
    if ($c -match '\s-m\s+([\w.]+)') { return $matches[1] }
    if ($c -match '[\\/]([\w.-]+)\.(?:m?js|cjs|ts|py)"?(\s|$)') { return $matches[1] }
    [IO.Path]::GetFileNameWithoutExtension($x.Name)
}
function Get-Role($s, $x) {
    $n = $x.Name.ToLowerInvariant(); $c = $x.Cmd
    if ($x.Kind -eq 'cli') {
        if ($x.TopCli -and $x.TopCli -ne $x.Id) { return 'agent-in-code' }
        if ($x.InApp) { return 'session' }
        if ($x.Model -match 'haiku' -or $c -match '--thinking=disabled') { return 'plugin-helper' }
        return 'session'
    }
    if ($x.Kind) { return $x.Kind }
    if (-not $x.Cli) { return '' }
    if ($n -match '\.test\.exe$' -or $c -match 'vitest|jest|pytest|mocha|playwright test|go(\.exe)?"? test|cargo test|bun test') { return 'test' }
    if ($n -eq 'chrome-headless-shell.exe' -or ($n -match '^(chrome|msedge)\.exe$' -and $c -match '--headless|--remote-debugging')) { return 'browser' }
    if ($c -match 'vite|next(\.js)? dev|next-server|webpack(-dev-server)? |astro dev|nodemon|tsx(\.cmd)?"? watch|run dev|run start|dev:|serve\b|uvicorn|flask run|http\.server') { return 'dev-server' }
    if ($c -match $LspPattern) { return 'lsp' }
    if ($ShellNames -contains $x.Name) { return 'shell' }
    $p = Get-ValidParent $s $x
    if ($p -and ($p.Id -eq $x.Cli -or ($p.Name -eq 'cmd.exe' -and $p.PPid -eq $x.Cli))) { return 'mcp' }
    'other'
}
function Set-Projects($s) {
    $clis = @($s.List | Where-Object { $_.Kind -eq 'cli' -and $_.SessionId })
    if (-not $clis.Count) { return }
    $root = Join-Path $ClaudeHome 'projects'
    if (-not (Test-Path $root)) { return }
    $dirs = @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue)
    foreach ($x in $clis) {
        foreach ($d in $dirs) { if (Test-Path (Join-Path $d.FullName "$($x.SessionId).jsonl")) { $x.Project = Get-ProjectLabel $d.Name; break } }
    }
}
function Get-ProjectLabel([string]$dir) {
    $enc = ($env:USERPROFILE -replace '[^A-Za-z0-9]', '-')
    $n = $dir
    if ($n.StartsWith($enc, [StringComparison]::OrdinalIgnoreCase)) { $n = '~\' + $n.Substring($enc.Length).TrimStart('-') }
    $n -replace '--claude-worktrees-', ' [worktree] '
}
function Get-Tree($s, $x) {
    $out = New-Object System.Collections.Generic.List[object]; $q = New-Object System.Collections.Generic.Queue[object]
    $q.Enqueue($x)
    while ($q.Count) { $c = $q.Dequeue(); $out.Add($c); if ($s.Kids.ContainsKey($c.Id)) { foreach ($k in $s.Kids[$c.Id]) { $q.Enqueue($k) } } }
    $out
}
function Get-OwnerLabel($s, $x) {
    if ($x.Kind -eq 'cli' -and -not $x.TopCli) { $top = $x } elseif ($x.TopCli) { $top = $s.ById[$x.TopCli] } else { $top = $null }
    if ($top) {
        $sid = if ($top.SessionId) { $top.SessionId.Substring(0, 8) } else { "pid $($top.Id)" }
        $p = if ($top.Project) { " $($top.Project)" } else { '' }
        if ($top.Role -eq 'plugin-helper') { return "Claude plugin helper ($sid)" }
        return "Claude session $sid$p"
    }
    if ($x.InApp) { return 'Claude desktop app' }
    [IO.Path]::GetFileNameWithoutExtension($x.Name)
}

# ---------------------------------------------------------------- sampling
function Get-IoCounters {
    $h = @{}
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, Name, ReadTransferCount, WriteTransferCount) { $h[[int]$p.ProcessId] = @([string]$p.Name, [double]$p.ReadTransferCount, [double]$p.WriteTransferCount) }
    $h
}
function Measure-Window([int]$sec) {
    $a = @{}; foreach ($p in Get-Process) { $c = 0.0; try { $c = [double]$p.CPU } catch { }; $a[$p.Id] = @($p.ProcessName, $p.HandleCount, $c) }
    $io1 = Get-IoCounters
    Start-Sleep -Seconds $sec
    $io2 = Get-IoCounters
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($p in Get-Process) {
        if (-not $a.ContainsKey($p.Id)) { continue }
        $o = $a[$p.Id]; if ($o[0] -ne $p.ProcessName) { continue }
        $c = 0.0; try { $c = [double]$p.CPU } catch { }
        $rd = 0.0; $wr = 0.0
        if ($io1.ContainsKey($p.Id) -and $io2.ContainsKey($p.Id) -and $io1[$p.Id][0] -eq $io2[$p.Id][0]) {
            $rd = [math]::Max(0, $io2[$p.Id][1] - $io1[$p.Id][1]) / 1MB; $wr = [math]::Max(0, $io2[$p.Id][2] - $io1[$p.Id][2]) / 1MB
        }
        $res.Add([pscustomobject]@{ Id = $p.Id; Name = $p.ProcessName; Handles = $p.HandleCount; HDelta = $p.HandleCount - $o[1]; CpuDelta = [math]::Max(0, $c - $o[2]); ReadMB = $rd; WriteMB = $wr })
    }
    [pscustomobject]@{ Seconds = $sec; Rows = $res }
}
function Get-LeakRows($w) {
    $svc = @{}
    try { foreach ($sv in Get-CimInstance Win32_Service -Filter 'ProcessId > 0') { $k = [int]$sv.ProcessId; if ($svc.ContainsKey($k)) { $svc[$k] += ", $($sv.Name)" } else { $svc[$k] = $sv.Name } } } catch { }
    $known = @(Get-KnownIssues)
    foreach ($r in $w.Rows) {
        $rate = [math]::Round($r.HDelta * 3600 / [math]::Max(1, $w.Seconds))
        # kernel processes swing by tens of thousands of handles; only a very high count means a leaking driver
        $kernel = $r.Id -le 4 -or $KernelNames -contains $r.Name
        $verdict = if ($kernel) { if ($r.Handles -ge 100000) { 'LEAK' } else { '' } }
        elseif ($r.Handles -ge 100000 -or ($rate -ge 50000 -and $r.Handles -ge 5000)) { 'LEAK' } elseif ($rate -ge 10000 -and $r.Handles -ge 10000) { 'suspicious' } else { '' }
        $k = $known | Where-Object { $_.process -eq $r.Name } | Select-Object -First 1
        [pscustomobject]@{ Id = $r.Id; Name = $r.Name; Service = $svc[$r.Id]; Handles = $r.Handles; PerHour = $rate; Verdict = $verdict; Known = $k; Kernel = $kernel }
    }
}

# ---------------------------------------------------------------- watchdog state
function Get-Watchdogs {
    $res = @()
    $tasks = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)
    $names = @{}
    foreach ($t in $tasks) { if ($t.TaskName -match '^watchdog-(.+)$') { $names[$matches[1]] = $t } }
    if (Test-Path $StateDir) { foreach ($f in Get-ChildItem $StateDir -Filter 'watchdog-*.ps1') { $n = $f.BaseName -replace '^watchdog-', ''; if (-not $names.ContainsKey($n)) { $names[$n] = $null } } }
    foreach ($n in $names.Keys) {
        $hb = Join-Path $StateDir "watchdog-$n.last"; $last = $null; $info = ''
        if (Test-Path $hb) { $last = (Get-Item $hb).LastWriteTime; $info = (Get-Content $hb -Raw).Trim() }
        $every = $Every
        $t = $names[$n]
        if ($t) { try { $iv = $t.Triggers[0].Repetition.Interval; if ($iv -match 'PT(\d+)M') { $every = [int]$matches[1] } } catch { } }
        $state = if (-not $t) { 'TASK MISSING' } elseif (-not $last) { 'never ran' } elseif (((Get-Date) - $last).TotalMinutes -gt 3 * $every + 2) { 'STALE' } else { 'ok' }
        $res += [pscustomobject]@{ Process = $n; State = $state; LastRun = $last; Info = $info; Every = $every }
    }
    $res
}

# ---------------------------------------------------------------- check
function Invoke-Check([int]$sec) {
    $findings = New-Object System.Collections.Generic.List[object]
    function Add-Finding([string]$sev, [string]$title, [string]$fix) { $findings.Add([pscustomobject]@{ Sev = $sev; Title = $title; Fix = $fix }) }

    Write-Host "overclock $Version  -  sampling for $sec s ..." -ForegroundColor DarkGray
    $w = Measure-Window $sec
    $s = Get-Snap
    $os = Get-CimInstance Win32_OperatingSystem
    $ramTotal = $os.TotalVisibleMemorySize / 1KB; $ramFree = $os.FreePhysicalMemory / 1KB
    $ramPct = [math]::Round(100 * ($ramTotal - $ramFree) / $ramTotal)
    $commitPct = [math]::Round(100 * ($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / $os.TotalVirtualMemorySize)
    $handles = ($s.List | Measure-Object Handles -Sum).Sum
    $threads = ($s.List | Measure-Object Threads -Sum).Sum

    Write-Head '== System'
    Write-Host ('RAM {0}% used ({1} free of {2})   commit {3}%   up {4}' -f $ramPct, (Format-MB $ramFree), (Format-MB $ramTotal), $commitPct, (Format-Age $os.LastBootUpTime))
    Write-Host ('{0:N0} processes   {1:N0} threads   {2:N0} handles' -f $s.List.Count, $threads, $handles)
    if ($ramPct -ge 90) { Add-Finding 'HIGH' "RAM is $ramPct % full." 'See "Who holds the RAM" above.' } elseif ($ramPct -ge 80) { Add-Finding 'WARN' "RAM is $ramPct % full." 'See "Who holds the RAM" above.' }
    if ($commitPct -ge 90) { Add-Finding 'HIGH' "Commit charge is at $commitPct % - Windows is about to run out of memory." 'Close sessions or programs now.' }
    if ($handles -ge 1000000) { Add-Finding 'HIGH' ('{0:N0} handles in total (normal: 100-300k).' -f $handles) 'overclock leaks' } elseif ($handles -ge 400000) { Add-Finding 'WARN' ('{0:N0} handles in total (normal: 100-300k).' -f $handles) 'overclock leaks' }

    $rowById = @{}; foreach ($r in $w.Rows) { $rowById[$r.Id] = $r }
    $owners = @{}
    foreach ($x in $s.List) {
        if ($x.Id -eq 0) { continue }
        $o = if ($x.Id -eq 4) { 'System (Windows kernel, paging)' } else { Get-OwnerLabel $s $x }
        if (-not $owners.ContainsKey($o)) { $owners[$o] = [pscustomobject]@{ Owner = $o; N = 0; Cpu = 0.0; MB = 0.0; Handles = 0; IO = 0.0 } }
        $e = $owners[$o]; $e.N++; $e.MB += $x.PrivMB; $e.Handles += $x.Handles
        if ($rowById.ContainsKey($x.Id)) { $r = $rowById[$x.Id]; $e.Cpu += $r.CpuDelta; $e.IO += $r.ReadMB + $r.WriteMB }
    }
    $cap = [double]$sec * $Cores
    Write-Head "== Who uses the CPU ($sec s, 100 % = all $Cores threads)"
    foreach ($e in ($owners.Values | Sort-Object Cpu -Descending | Select-Object -First 8)) {
        if ($e.Cpu -le 0) { continue }
        Write-Host ('{0,5:N1} %  {1,4} proc  {2}' -f (100 * $e.Cpu / $cap), $e.N, (Limit-Text $e.Owner 90))
    }
    $totalCpu = ($owners.Values | Measure-Object Cpu -Sum).Sum
    if (100 * $totalCpu / $cap -ge 85) { Add-Finding 'HIGH' ('CPU at {0:N0} %.' -f (100 * $totalCpu / $cap)) 'See "Who uses the CPU" above.' }

    Write-Head '== Who holds the RAM (private memory)'
    foreach ($e in ($owners.Values | Sort-Object MB -Descending | Select-Object -First 8)) {
        Write-Host ('{0,9}  {1,4} proc  {2}' -f (Format-MB $e.MB), $e.N, (Limit-Text $e.Owner 90))
    }
    Write-Head "== Who reads and writes ($sec s, files + pipes + network)"
    foreach ($e in ($owners.Values | Sort-Object IO -Descending | Select-Object -First 6)) {
        if ($e.IO -lt 0.1) { continue }
        Write-Host ('{0,7:N1} MB/s  {1,4} proc  {2}' -f ($e.IO / $sec), $e.N, (Limit-Text $e.Owner 90))
    }
    $df = Get-DiskFacts
    if ($null -ne $df.Busy) { Write-Host ('Disk busy: {0:N0} %' -f $df.Busy) }
    foreach ($f in (Get-DiskFindings $df)) { Add-Finding $f.Sev $f.Title $f.Fix }
    $vmProc = Get-Process -Name vmmem, vmmemWSL -ErrorAction SilentlyContinue | Measure-Object WorkingSet64 -Sum
    if ($vmProc.Sum -ge 4GB) { Add-Finding 'INFO' ('WSL/Docker VM (vmmem) uses {0}.' -f (Format-MB ($vmProc.Sum / 1MB))) 'Cap it with memory=8GB in %UserProfile%\.wslconfig, then "wsl --shutdown".' }

    Write-Head "== Handles (growth over $sec s)"
    $leak = @(Get-LeakRows $w)
    foreach ($r in ($leak | Sort-Object Handles -Descending | Select-Object -First 5)) {
        $tag = if ($r.Verdict) { "  <-- $($r.Verdict)" } else { '' }
        $sv = if ($r.Service) { " ($($r.Service))" } else { '' }
        Write-Host ('{0,10:N0}  {1,9:+#,0;-#,0;0}/h  {2}{3}{4}' -f $r.Handles, $r.PerHour, $r.Name, $sv, $tag)
    }
    $wd = @(Get-Watchdogs)
    foreach ($r in ($leak | Where-Object { $_.Verdict -eq 'LEAK' })) {
        if ($r.Kernel) {
            Add-Finding 'WARN' ('The Windows kernel ({0}) holds {1:N0} handles: a driver is leaking them.' -f $r.Name, $r.Handles) "overclock handles $($r.Name)   (admin; shows the object type), then update drivers. No watchdog for kernel processes."
            continue
        }
        $fix = if ($r.Service -and $r.Service -notmatch ',') { "overclock watchdog install $($r.Name)" } else { "overclock handles $($r.Name)   (shows what it holds); update or restart that program" }
        if ($r.Known) { $fix = "$($r.Known.fix)" }
        $guard = $wd | Where-Object { $_.Process -eq $r.Name -and $_.State -eq 'ok' } | Select-Object -First 1
        if ($guard) {
            Add-Finding 'INFO' ('{0} leaks handles ({1:N0} now, about {2:N0} more per hour); your watchdog keeps it in check.' -f $r.Name, $r.Handles, $r.PerHour) $(if ($r.Known) { "Real fix: $(($r.Known.fix -split '\. Until then')[0])." } else { 'Real fix: update the driver of this service.' })
        } else {
            Add-Finding 'HIGH' ('{0} leaks handles: {1:N0} now, about {2:N0} more per hour.' -f $r.Name, $r.Handles, $r.PerHour) $fix
        }
    }
    foreach ($d in $wd) {
        if ($d.State -ne 'ok') { Add-Finding 'HIGH' "Watchdog for $($d.Process): $($d.State)." "overclock watchdog install $($d.Process)   (something removed or stopped it)" }
    }

    Write-Head '== Claude'
    $app = @($s.List | Where-Object { $_.InApp -and -not $_.TopCli -and $_.Kind -ne 'cli' })
    $sessions = @($s.List | Where-Object { $_.Role -eq 'session' })
    $helpers = @($s.List | Where-Object { $_.Role -eq 'plugin-helper' })
    $nested = @($s.List | Where-Object { $_.Role -eq 'agent-in-code' })
    $mcp = @($s.List | Where-Object { $_.Role -eq 'mcp' })
    $orph = @(Get-Orphans $s)
    $appMB = ($app | Measure-Object PrivMB -Sum).Sum
    Write-Host ('Desktop app: {0} processes, {1}' -f $app.Count, (Format-MB $appMB))
    Write-Host ('Sessions running: {0}   plugin helpers: {1}   agents started by your code: {2}' -f $sessions.Count, $helpers.Count, $nested.Count)
    $roles = $s.List | Where-Object { $_.Cli } | Group-Object Role
    $rs = ($roles | Sort-Object Count -Descending | ForEach-Object { "$($_.Count) $($_.Name)" }) -join ', '
    if ($rs) { Write-Host "Started by sessions: $rs" }
    $mcpGroups = $mcp | Group-Object { Get-Label $_ } | Sort-Object Count -Descending
    foreach ($g in ($mcpGroups | Select-Object -First 6)) {
        Write-Host ('  MCP {0,-28} x{1,-3} {2}' -f $g.Name, $g.Count, (Format-MB (($g.Group | ForEach-Object { (Get-Tree $s $_) } | Measure-Object PrivMB -Sum).Sum)))
    }
    $act = Get-AgentActivity 1
    Write-Host ('Last hour: {0} sessions active, {1} subagents started, {2} workflow(s) running, peak {3} agents at once' -f $act.Sessions, $act.Subagents, $act.Running.Count, $act.Peak)

    if ($sessions.Count -ge 10) { Add-Finding 'WARN' "$($sessions.Count) Claude Code sessions are running at the same time. The desktop app resumes every open session after a restart." 'Archive the sessions you are not using; each one keeps its own CLI and MCP servers alive.' }
    foreach ($g in $mcpGroups) {
        if ($g.Count -ge 5 -and $g.Count -ge [math]::Max(1, $sessions.Count) - 1) {
            Add-Finding 'WARN' ('MCP server "{0}" runs {1} times (once per session).' -f $g.Name, $g.Count) 'If you need it only in some projects, move it from your user config to those projects'' .mcp.json.'
        }
    }
    $lsps = @(Get-LspTrees $s)
    if ($lsps.Count) {
        $lspMB = ($lsps | Measure-Object MB -Sum).Sum
        foreach ($g in $lsps | Group-Object Name) { Write-Host ('  LSP {0,-28} x{1,-3} {2}' -f $g.Name, $g.Count, (Format-MB (($g.Group | Measure-Object MB -Sum).Sum))) }
        if ($lspMB -ge 3000) {
            $fix = if ((Get-AutopilotState).State -eq 'ok') { 'Autopilot ends the ones idle for 30 min (Claude Code starts them again when needed). Not needed at all? claude plugin disable <name>-lsp' } else { 'overclock autopilot install   (ends idle ones; Claude Code starts them again when needed), or: claude plugin disable <name>-lsp' }
            Add-Finding $(if ($lspMB -ge 8000) { 'HIGH' } else { 'WARN' }) ('{0} language servers from LSP plugins hold {1} (one per session). With too little RAM Windows moves this to the page file: disk at 100 %.' -f $lsps.Count, (Format-MB $lspMB)) $fix
        }
    }
    if ($act.Peak -ge 8) { Add-Finding 'HIGH' "Up to $($act.Peak) agents ran at the same time in the last hour (workflows/subagents)." 'overclock agents   - each agent runs its own builds and tests; cap parallel agents in your workflow.' }
    if ($nested.Count -ge 1) { Add-Finding 'WARN' "$($nested.Count) Claude Code processes were started by code or tests that a session ran (not by you)." 'overclock sessions   - look for "agent-in-code"; e2e tests that spawn real agents multiply everything.' }
    $dev = @($s.List | Where-Object { $_.Role -eq 'dev-server' -and $_.Name -ne 'cmd.exe' -and $_.Name -notmatch 'bash|sh\.exe' })
    $br = @($s.List | Where-Object { $_.Role -eq 'browser' -and $_.Cmd -notmatch '--type=' })
    $tests = @($s.List | Where-Object { $_.Role -eq 'test' -and $_.Name -notmatch '^(bash|sh|cmd)\.exe$' })
    if ($dev.Count -ge 4) { Add-Finding 'WARN' "$($dev.Count) dev-server processes started by sessions." 'overclock orphans   - several may be duplicates of the same app.' }
    if ($br.Count -ge 4) { Add-Finding 'WARN' "$($br.Count) headless browsers started by sessions." 'Close finished browser/Playwright sessions; overclock orphans finds left-overs.' }
    if ($tests.Count -ge 6) { Add-Finding 'INFO' "$($tests.Count) test processes are running right now." 'Normal while agents test; many at once means parallel agents.' }
    $ready = @($orph | Where-Object { -not $_.Expected -and -not $_.Young })
    $young = @($orph | Where-Object { -not $_.Expected -and $_.Young }).Count
    $later = if ($young) { "; $young younger one(s) may still be working" } else { '' }
    $ap = Get-AutopilotState
    if ($ready.Count) {
        $fix = if ($ap.State -eq 'ok') { 'overclock reap -Kill   (autopilot ends the ones it knows on its next run)' } else { 'overclock reap -Kill, or let it happen automatically: overclock autopilot install' }
        Add-Finding 'WARN' ('{0} orphaned process trees ({1}) from sessions that are gone{2}.' -f $ready.Count, (Format-MB (($ready | Measure-Object MB -Sum).Sum)), $later) $fix
    }
    if ($ap.State -ne 'ok' -and $ap.State -ne 'off') { Add-Finding 'HIGH' "Autopilot: $($ap.State)." 'overclock autopilot install   (something removed or stopped it)' }
    elseif ($ap.State -eq 'off' -and $sessions.Count -ge 5) { Add-Finding 'INFO' 'Autopilot is off: orphans and new sessions are not handled automatically.' 'overclock autopilot install   (every 10 min: ends orphaned Claude trees, keeps Claude at below-normal priority)' }

    Write-Head '== Findings'
    if (-not $findings.Count) { Write-Good 'Nothing unusual found.' }
    foreach ($sev in 'HIGH', 'WARN', 'INFO') {
        foreach ($f in $findings | Where-Object { $_.Sev -eq $sev }) {
            $c = switch ($sev) { 'HIGH' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
            Write-Host ("[$sev] " + $f.Title) -ForegroundColor $c
            if ($f.Fix) { Write-Host ('       -> ' + $f.Fix) -ForegroundColor DarkGray }
        }
    }
    [pscustomobject]@{ Snap = $s; Window = $w; Findings = $findings; RamPct = $ramPct; CommitPct = $commitPct; Handles = $handles; Owners = $owners.Values; Leaks = $leak; Activity = $act; Watchdogs = $wd }
}

# ---------------------------------------------------------------- sessions
function Invoke-Sessions {
    $s = Get-Snap
    $ports = @{}
    try { foreach ($c in Get-NetTCPConnection -State Listen -ErrorAction Stop) { $k = [int]$c.OwningProcess; if (-not $ports.ContainsKey($k)) { $ports[$k] = New-Object System.Collections.Generic.List[int] }; if (-not $ports[$k].Contains([int]$c.LocalPort)) { $ports[$k].Add([int]$c.LocalPort) } } } catch { }
    $clis = @($s.List | Where-Object { $_.Kind -eq 'cli' } | Sort-Object Created)
    if (-not $clis.Count) { Write-Host 'No Claude Code process is running.'; return }
    foreach ($x in $clis) {
        $tree = @(Get-Tree $s $x)
        $mine = @($tree | Where-Object { $_.Id -eq $x.Id -or $_.Cli -eq $x.Id })
        $mb = ($mine | Measure-Object PrivMB -Sum).Sum; $h = ($mine | Measure-Object Handles -Sum).Sum
        $sid = if ($x.SessionId) { $x.SessionId.Substring(0, 8) } else { "pid $($x.Id)" }
        $c = switch ($x.Role) { 'agent-in-code' { 'Magenta' } 'plugin-helper' { 'DarkGray' } default { 'Cyan' } }
        Write-Host ''
        Write-Host ('{0}  {1}  {2}  {3}' -f $sid, $x.Role, $x.Model, $x.Project) -ForegroundColor $c
        Write-Host ('   pid {0}, running {1}, {2} processes, {3}, {4:N0} handles' -f $x.Id, (Format-Age $x.Created), $mine.Count, (Format-MB $mb), $h)
        if ($x.Role -eq 'agent-in-code') { $p = Get-ValidParent $s $x; Write-Host ('   started by: {0}' -f (Limit-Text ("$($p.Name) " + $p.Cmd) 110)) -ForegroundColor DarkGray }
        foreach ($g in ($mine | Where-Object { $_.Id -ne $x.Id -and $_.Role -ne 'shell' } | Group-Object Role | Sort-Object Count -Descending)) {
            $items = $g.Group | Group-Object { Get-Label $_ } | Sort-Object Count -Descending | ForEach-Object { $pp = @($_.Group | ForEach-Object { if ($ports.ContainsKey($_.Id)) { $ports[$_.Id] } }); $ps = if ($pp.Count) { ' :' + (($pp | Sort-Object -Unique) -join ',:') } else { '' }; if ($_.Count -gt 1) { "$($_.Name) x$($_.Count)$ps" } else { "$($_.Name)$ps" } }
            Write-Host ('   {0,-14} {1}' -f $g.Name, (Limit-Text ($items -join ', ') 100))
        }
        $sh = @($mine | Where-Object { $_.Role -eq 'shell' }).Count
        if ($sh) { Write-Host ('   {0,-14} {1} (bash/cmd/powershell/conhost)' -f 'shells', $sh) }
    }
    $sess = @($clis | Where-Object { $_.Role -eq 'session' }).Count
    Write-Head ('{0} sessions, {1} agents started by code, {2} plugin helpers' -f $sess, @($clis | Where-Object { $_.Role -eq 'agent-in-code' }).Count, @($clis | Where-Object { $_.Role -eq 'plugin-helper' }).Count)
}

# ---------------------------------------------------------------- agents (from the session logs)
function Get-AgentActivity([int]$hours) {
    $since = (Get-Date).AddHours(-$hours)
    $root = Join-Path $ClaudeHome 'projects'
    $files = @()
    if (Test-Path $root) { $files = @(Get-ChildItem $root -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since }) }
    $sub = @($files | Where-Object { $_.FullName -match '\\subagents\\' })
    $main = @($files | Where-Object { $_.FullName -notmatch '\\subagents\\' })
    $wf = @{}
    foreach ($f in $sub) {
        if ($f.FullName -match '\\subagents\\workflows\\(wf_[^\\]+)\\') {
            $k = $matches[1]
            if (-not $wf.ContainsKey($k)) { $wf[$k] = [pscustomobject]@{ Id = $k; Agents = 0; First = $f.CreationTime; Last = $f.LastWriteTime; Project = (Get-ProjectLabel ($f.FullName.Substring($root.Length + 1).Split('\')[0])) } }
            $e = $wf[$k]; $e.Agents++
            if ($f.CreationTime -lt $e.First) { $e.First = $f.CreationTime }
            if ($f.LastWriteTime -gt $e.Last) { $e.Last = $f.LastWriteTime }
        }
    }
    $ev = New-Object System.Collections.Generic.List[object]
    foreach ($f in $sub) { $st = [datetime]$f.CreationTime; if ($st -lt $since) { $st = $since }; $ev.Add(@($st, 1)); $ev.Add(@([datetime]$f.LastWriteTime, -1)) }
    $peak = 0; $peakAt = $null; $cur = 0
    foreach ($e in ($ev | Sort-Object { $_[0] }, { $_[1] })) { $cur += $e[1]; if ($cur -gt $peak) { $peak = $cur; $peakAt = $e[0] } }
    $running = @($wf.Values | Where-Object { $_.Last -ge (Get-Date).AddMinutes(-10) })
    [pscustomobject]@{
        Hours = $hours; Sessions = $main.Count; Subagents = @($sub | Where-Object { $_.CreationTime -ge $since }).Count
        Workflows = @($wf.Values); Running = $running; Peak = $peak; PeakAt = $peakAt; SubFiles = $sub; Root = $root
    }
}
function Invoke-Agents {
    $a = Get-AgentActivity $Hours
    Write-Head ("== Agent activity, last $Hours h (from $(Hide-Paths $a.Root))")
    Write-Host ('{0} sessions wrote to their log, {1} subagents started, peak {2} agents at once{3}' -f $a.Sessions, $a.Subagents, $a.Peak, $(if ($a.PeakAt) { ' at ' + $a.PeakAt.ToString('dd.MM. HH:mm') } else { '' }))
    $byHour = $a.SubFiles | Where-Object { $_.CreationTime -ge (Get-Date).AddHours(-$Hours) } | Group-Object { $_.CreationTime.ToString('dd.MM. HH:00') } | Sort-Object Name
    if ($byHour) {
        Write-Head '== Subagents started per hour'
        $max = ($byHour | Measure-Object Count -Maximum).Maximum
        foreach ($b in $byHour) { Write-Host ('{0}  {1,4}  {2}' -f $b.Name, $b.Count, ('#' * [math]::Max(1, [math]::Round(50 * $b.Count / $max)))) }
    }
    if ($a.Workflows.Count) {
        Write-Head '== Workflows'
        foreach ($w in ($a.Workflows | Sort-Object First)) {
            $state = if ($a.Running -contains $w) { 'RUNNING' } else { 'done' }
            Write-Host ('{0}  {1,-8} {2,3} agents  {3} - {4}  {5}' -f $w.Id, $state, $w.Agents, $w.First.ToString('dd.MM. HH:mm'), $w.Last.ToString('HH:mm'), $w.Project)
        }
    }
    $top = $a.SubFiles | Group-Object { $p = $_.FullName.Substring($a.Root.Length + 1).Split('\'); "$(Get-ProjectLabel $p[0])  (session $($p[1].Substring(0, [math]::Min(8, $p[1].Length))))" } | Sort-Object Count -Descending | Select-Object -First 8
    if ($top) {
        Write-Head '== Sessions that started the most agents'
        foreach ($t in $top) { Write-Host ('{0,5}  {1}' -f $t.Count, $t.Name) }
    }
}

# ---------------------------------------------------------------- leaks and handle types
function Invoke-Leaks {
    $sec = if ($Seconds) { $Seconds } else { 60 }
    Write-Host "Sampling handle counts for $sec s ..." -ForegroundColor DarkGray
    $before = (Get-Process | Measure-Object HandleCount -Sum).Sum
    $w = Measure-Window $sec
    $after = (Get-Process | Measure-Object HandleCount -Sum).Sum
    Write-Head '== Growing handle counts'
    Write-Host ('System: {0:N0} -> {1:N0} handles ({2:+#,0;-#,0;0} in {3} s)' -f $before, $after, ($after - $before), $sec)
    $rows = @(Get-LeakRows $w | Where-Object { $_.PerHour -gt 0 } | Sort-Object PerHour -Descending | Select-Object -First 12)
    if (-not $rows.Count) { Write-Good 'No process gained handles.'; return }
    foreach ($r in $rows) {
        $c = switch ($r.Verdict) { 'LEAK' { 'Red' } 'suspicious' { 'Yellow' } default { 'Gray' } }
        $sv = if ($r.Service) { " (service $($r.Service))" } else { '' }
        Write-Host ('{0,10:N0} handles  {1,10:+#,0;-#,0;0}/h  pid {2,-6} {3}{4}  {5}' -f $r.Handles, $r.PerHour, $r.Id, $r.Name, $sv, $r.Verdict) -ForegroundColor $c
    }
    foreach ($r in $rows | Where-Object { $_.Verdict -eq 'LEAK' }) {
        Write-Host ''
        if ($r.Known) {
            Write-Warn2 "$($r.Name) is a known leak: $($r.Known.device), driver $($r.Known.driverVersions -join ', ')."
            Write-Host "   Fix: $($r.Known.fix)"
        }
        if ($r.Kernel) { Write-Host '   This is the Windows kernel: a driver leaks handles into it. Update drivers (Bluetooth, network, GPU, RGB tools first). No watchdog possible.' }
        elseif ($r.Service -and $r.Service -notmatch ',') { Write-Host "   Stop-gap: overclock watchdog install $($r.Name)   (restarts the service $($r.Service) above -Threshold handles)" }
        Write-Host "   Details: overclock handles $($r.Name)"
    }
    Write-Host ''
    Write-Host 'Short-lived processes that stay in kernel memory do not show up here; for that see' $ZombieRepo -ForegroundColor DarkGray
}
function Invoke-Handles {
    Assert-Admin
    if (-not $Target) { Write-Bad 'Usage: overclock handles <process name or pid>'; exit 2 }
    $p = if ($Target -match '^\d+$') { Get-Process -Id ([int]$Target) } else { Get-Process -Name ($Target -replace '\.exe$', '') | Sort-Object HandleCount -Descending | Select-Object -First 1 }
    $types = @{}; foreach ($t in [Overclock.Native]::Types()) { $types[$t.Index] = $t }
    $h = [Overclock.Native]::HandleTypes($p.Id)
    $total = 0; foreach ($v in $h.Values) { $total += $v }
    Write-Head ('== {0} (pid {1}): {2:N0} handles' -f $p.ProcessName, $p.Id, $total)
    foreach ($k in ($h.Keys | Sort-Object { $h[$_] } -Descending | Select-Object -First 12)) {
        $n = if ($types.ContainsKey($k)) { $types[$k].Name } else { "type $k" }
        Write-Host ('{0,10:N0}  {1,5:N1} %  {2}' -f $h[$k], (100.0 * $h[$k] / [math]::Max(1, $total)), $n)
    }
    $proc = $types.Values | Where-Object { $_.Name -eq 'Process' } | Select-Object -First 1
    if ($proc) {
        $live = @(Get-Process).Count
        Write-Host ''
        Write-Host ('System-wide: {0:N0} process objects for {1:N0} running processes' -f $proc.Objects, $live) -ForegroundColor DarkGray
        if ($proc.Objects - $live -gt 5000) { Write-Warn2 "That is $($proc.Objects - $live) exited processes still in memory - see $ZombieRepo" }
    }
}

# ---------------------------------------------------------------- spawns
function Invoke-Spawns {
    Assert-Admin
    $sec = if ($Seconds) { $Seconds } else { 60 }
    $s = Get-Snap
    $map = @{}; foreach ($x in $s.List) { $map[$x.Id] = @($x.Name, $x.PPid) }
    $sid = 'overclock-spawn'
    Register-CimIndicationEvent -ClassName Win32_ProcessStartTrace -SourceIdentifier $sid | Out-Null
    Write-Host "Counting process starts for $sec s ..." -ForegroundColor DarkGray
    $events = New-Object System.Collections.Generic.List[object]
    $end = (Get-Date).AddSeconds($sec)
    try {
        while ((Get-Date) -lt $end) {
            Start-Sleep -Milliseconds 500
            foreach ($e in @(Get-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue)) {
                $n = $e.SourceEventArgs.NewEvent
                $events.Add(@([string]$n.ProcessName, [int]$n.ProcessID, [int]$n.ParentProcessID)); $map[[int]$n.ProcessID] = @([string]$n.ProcessName, [int]$n.ParentProcessID)
                Remove-Event -EventIdentifier $e.EventIdentifier
            }
        }
    } finally { Unregister-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue; Get-Event -SourceIdentifier $sid -ErrorAction SilentlyContinue | Remove-Event }
    $owner = @{}
    foreach ($e in $events) {
        $cur = $e[2]; $label = $null
        for ($i = 0; $i -lt 40 -and $cur; $i++) {
            $x = $s.ById[$cur]
            if ($x -and ($x.Kind -eq 'cli' -or $x.TopCli -or $x.InApp)) { $label = Get-OwnerLabel $s $x; break }
            if (-not $map.ContainsKey($cur)) { break }
            $next = $map[$cur][1]; if ($next -eq $cur) { break }; $cur = $next
        }
        if (-not $label) { $label = if ($map.ContainsKey($e[2])) { "other (parent $($map[$e[2]][0]))" } else { 'other (parent gone)' } }
        if ($owner.ContainsKey($label)) { $owner[$label]++ } else { $owner[$label] = 1 }
    }
    Write-Head ('== {0:N0} process starts in {1} s = {2:N0} per minute' -f $events.Count, $sec, ($events.Count * 60 / $sec))
    foreach ($g in ($events | Group-Object { $_[0] } | Sort-Object Count -Descending | Select-Object -First 10)) { Write-Host ('{0,7:N0}  {1}' -f $g.Count, $g.Name) }
    Write-Head '== Started on behalf of'
    foreach ($k in ($owner.Keys | Sort-Object { $owner[$_] } -Descending | Select-Object -First 10)) { Write-Host ('{0,7:N0}  {1}' -f $owner[$k], (Limit-Text $k 100)) }
    Write-Host ''
    Write-Host 'Each tool call starts a shell, conhost and every configured hook. If RAM disappears without an owner, test for kernel zombies:' -ForegroundColor DarkGray
    Write-Host "  $ZombieRepo" -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- orphans
function Get-Orphans($s) {
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($x in $s.List) {
        if ($WatchNames -notcontains $x.Name -and $x.Name -notmatch '\.test\.exe$') { continue }
        if ($x.Name -match '^(chrome|msedge)\.exe$' -and $x.Cmd -notmatch '--headless|--remote-debugging') { continue }
        if (Get-ValidParent $s $x) { continue }
        if ($x.PPid -eq 0 -or $x.Id -le 4) { continue }
        $tree = @(Get-Tree $s $x)
        $expected = $x.Cmd -match 'worker-service|claude-mem.*worker|--daemon\b|tailscale|docker'
        $res.Add([pscustomobject]@{
                Root = $x; Tree = $tree; Count = $tree.Count; MB = ($tree | Measure-Object PrivMB -Sum).Sum; Cpu = ($tree | Measure-Object Cpu -Sum).Sum
                Handles = ($tree | Measure-Object Handles -Sum).Sum; Expected = $expected; Young = (((Get-Date) - $x.Created).TotalMinutes -lt $MinAgeMinutes)
            })
    }
    $res
}
function Invoke-Orphans {
    $s = Get-Snap
    $orph = @(Get-Orphans $s | Sort-Object { $_.Root.Created })
    $ports = @{}
    try { foreach ($c in Get-NetTCPConnection -State Listen -ErrorAction Stop) { $ports[[int]$c.OwningProcess] = @($ports[[int]$c.OwningProcess]) + [int]$c.LocalPort } } catch { }
    if (-not $orph.Count) { Write-Good 'No orphaned process trees.'; return }
    Write-Head '== Process trees whose starting session or shell is gone'
    $i = 0
    foreach ($o in $orph) {
        $i++
        $pp = @($o.Tree | ForEach-Object { if ($ports.ContainsKey($_.Id)) { $ports[$_.Id] } } | Where-Object { $_ } | Sort-Object -Unique)
        $tag = if ($o.Expected) { '  (background service - leave it)' } elseif ($o.Young) { "  (younger than $MinAgeMinutes min - may still be working)" } else { '' }
        $c = if ($o.Expected) { 'DarkGray' } elseif ($o.Young) { 'Yellow' } else { 'White' }
        Write-Host ('{0,2}. pid {1,-6} age {2,-7} {3,3} proc  {4,8}  cpu {5,6:N0}s{6}{7}' -f $i, $o.Root.Id, (Format-Age $o.Root.Created), $o.Count, (Format-MB $o.MB), $o.Cpu, $(if ($pp.Count) { '  ports :' + ($pp -join ',:') } else { '' }), $tag) -ForegroundColor $c
        $what = $o.Tree | Where-Object { $_.Name -notmatch '^(bash|sh|cmd|conhost)\.exe$' } | Select-Object -First 1
        if (-not $what) { $what = $o.Root }
        Write-Host ('    {0}' -f (Limit-Text (Hide-Paths "$($what.Name) $($what.Cmd -replace '^"?[^"]*\\', '')") 120)) -ForegroundColor DarkGray
    }
    $killable = @($orph | Where-Object { -not $_.Expected -and -not $_.Young })
    $mb = ($killable | Measure-Object MB -Sum).Sum
    Write-Host ''
    Write-Host ('{0} trees can be ended safely, {1} together.' -f $killable.Count, (Format-MB $mb))
    if (-not $Kill) { if ($killable.Count) { Write-Host 'Run with -Kill to end them (asks per tree; -Yes skips the questions).' -ForegroundColor DarkGray }; return }
    $done = 0; $failed = 0
    foreach ($o in $killable) {
        if (-not (Confirm-Step ("End pid $($o.Root.Id) and its $($o.Count - 1) child processes?"))) { continue }
        if (Stop-OrphanTree $o) { $done++ } else { $failed++; Write-Warn2 "pid $($o.Root.Id) is still running." }
    }
    Write-Good "Ended $done tree(s)."
    if ($failed) { Write-Warn2 "$failed tree(s) could not be ended; run as administrator." }
}
function Get-LspTrees($s) {
    foreach ($x in $s.List) {
        if (-not $x.Cli -or $x.Cmd -notmatch $LspPattern) { continue }
        $p = Get-ValidParent $s $x
        if ($p -and $p.Cmd -match $LspPattern) { continue }   # only the top of each language server tree (often a cmd.exe shim)
        $tree = @(Get-Tree $s $x)
        $name = if ($x.Cmd -match '(typescript-language-server|pyright-langserver|basedpyright-langserver|gopls|rust-analyzer|vscode-[\w-]+-language-server|intelephense|jdtls|clangd)') { $matches[1] } else { $x.Name }
        [pscustomobject]@{ Root = $x; Tree = $tree; Count = $tree.Count; Name = $name; Cli = $x.Cli
            MB = ($tree | Measure-Object PrivMB -Sum).Sum; Cpu = ($tree | Measure-Object Cpu -Sum).Sum }
    }
}
function Stop-OrphanTree($o) {
    # taskkill writes to stderr when a child already exited; under PS 5.1 that must not abort the caller
    $null = & cmd.exe /c "taskkill /PID $($o.Root.Id) /T /F >nul 2>&1"
    $still = Get-CimInstance Win32_Process -Filter "ProcessId=$($o.Root.Id)" -ErrorAction SilentlyContinue
    # the creation time check keeps us from touching a new process that reused the pid
    if ($still -and $still.CreationDate -eq $o.Root.Created) {
        Stop-Process -Id $o.Root.Id -Force -ErrorAction SilentlyContinue
        $still = Get-CimInstance Win32_Process -Filter "ProcessId=$($o.Root.Id)" -ErrorAction SilentlyContinue
    }
    -not ($still -and $still.CreationDate -eq $o.Root.Created)
}

# ---------------------------------------------------------------- watchdog
$WatchdogTemplate = @'
$ProcessName = '__PROCESS__'; $ServiceName = '__SERVICE__'; $Threshold = __THRESHOLD__
$Dir = '__DIR__'
$Log = Join-Path $Dir "watchdog-$ProcessName.log"; $Beat = Join-Path $Dir "watchdog-$ProcessName.last"
$p = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Sort-Object HandleCount -Descending | Select-Object -First 1
$h = if ($p) { $p.HandleCount } else { 0 }
Set-Content -Path $Beat -Value ("{0}  handles={1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $h)
if (-not $p -or $h -lt $Threshold) { exit 0 }
if ((Test-Path $Log) -and (Get-Item $Log).Length -gt 1MB) { Move-Item $Log "$Log.old" -Force }
try {
    Restart-Service -Name $ServiceName -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
    $a = (Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Select-Object -First 1).HandleCount
    Add-Content $Log ("{0}  restarted {1}: {2} -> {3} handles" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ServiceName, $h, $a)
} catch {
    Add-Content $Log ("{0}  FAILED to restart {1} at {2} handles: {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ServiceName, $h, $_.Exception.Message)
    exit 1
}
'@
function Invoke-Watchdog {
    switch ($Target) {
        'install' {
            Assert-Admin
            $proc = ($Name -replace '\.exe$', '')
            if (-not $proc) { Write-Bad 'Usage: overclock watchdog install <process> [-Service NAME] [-Threshold 100000] [-Every 5]'; exit 2 }
            $svc = $Service
            if (-not $svc) {
                $p = Get-Process -Name $proc -ErrorAction SilentlyContinue | Select-Object -First 1
                if (-not $p) { Write-Bad "Process $proc is not running; pass -Service NAME."; exit 2 }
                $hosted = @(Get-CimInstance Win32_Service -Filter "ProcessId=$($p.Id)")
                if ($hosted.Count -ne 1) { Write-Bad ("$proc hosts {0} services ({1}); restarting it would restart all of them. Pass -Service NAME if you are sure." -f $hosted.Count, (($hosted | ForEach-Object Name) -join ', ')); exit 2 }
                $svc = $hosted[0].Name
            }
            New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
            $file = Join-Path $StateDir "watchdog-$proc.ps1"
            $WatchdogTemplate.Replace('__PROCESS__', $proc).Replace('__SERVICE__', $svc).Replace('__THRESHOLD__', [string]$Threshold).Replace('__DIR__', $StateDir) | Set-Content -Path $file -Encoding UTF8
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$file`""
            $t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $Every)
            $t2 = New-ScheduledTaskTrigger -AtStartup
            $pr = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
            Register-ScheduledTask -TaskPath $TaskPath -TaskName "watchdog-$proc" -Action $action -Trigger $t1, $t2 -Principal $pr -Settings $st -Description "overclock: restarts service $svc when $proc holds more than $Threshold handles." -Force | Out-Null
            $beat = Join-Path $StateDir "watchdog-$proc.last"
            if (Test-Path $beat) { Remove-Item $beat -Force }
            Start-ScheduledTask -TaskPath $TaskPath -TaskName "watchdog-$proc"
            for ($i = 0; $i -lt 30 -and -not (Test-Path $beat); $i++) { Start-Sleep -Seconds 1 }
            if (-not (Test-Path $beat)) { Write-Warn2 'The first run has not reported back yet; check "overclock watchdog status" in a minute.' }
            Write-Good "Watchdog installed: every $Every min, restarts $svc above $('{0:N0}' -f $Threshold) handles of $proc."
            Write-Host "   script: $file"
            Write-Host '   check it any time with: overclock watchdog status'
        }
        'remove' {
            Assert-Admin
            $proc = ($Name -replace '\.exe$', '')
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName "watchdog-$proc" -Confirm:$false -ErrorAction SilentlyContinue
            Get-ChildItem $StateDir -Filter "watchdog-$proc.*" -ErrorAction SilentlyContinue | Remove-Item -Force
            Write-Good "Watchdog for $proc removed."
        }
        default {
            $wd = @(Get-Watchdogs)
            if (-not $wd.Count) { Write-Host 'No watchdog installed.'; return }
            foreach ($d in $wd) {
                $c = if ($d.State -eq 'ok') { 'Green' } else { 'Red' }
                Write-Host ('{0,-20} {1,-13} every {2} min   last run: {3}' -f $d.Process, $d.State, $d.Every, $d.Info) -ForegroundColor $c
                $log = Join-Path $StateDir "watchdog-$($d.Process).log"
                if (Test-Path $log) { Get-Content $log -Tail 3 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray } }
                if ($d.State -eq 'TASK MISSING') { Write-Warn2 '   The scheduled task is gone but its files are still here. Something deleted it; reinstall with "watchdog install".' }
            }
        }
    }
}

# ---------------------------------------------------------------- disk
function Test-Dramless([string]$model) {
    $f = Join-Path $ScriptDir 'known-issues.json'
    if (-not (Test-Path $f)) { return $false }
    foreach ($p in @((Get-Content $f -Raw | ConvertFrom-Json).dramlessSsds)) { if ($model -match $p) { return $true } }
    $false
}
function Get-DiskFacts {
    $admin = Test-Admin
    $disks = foreach ($d in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $r = $null; if ($admin) { try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { } }
        [pscustomobject]@{
            Name = [string]$d.FriendlyName; Media = [string]$d.MediaType; Bus = [string]$d.BusType; GB = [math]::Round($d.Size / 1GB); Health = [string]$d.HealthStatus
            Temp = $(if ($r) { $r.Temperature }); TempMax = $(if ($r) { $r.TemperatureMax }); Wear = $(if ($r) { $r.Wear })
            Errors = $(if ($r) { [int]$r.ReadErrorsUncorrected + [int]$r.WriteErrorsUncorrected }); Dramless = (Test-Dramless $d.FriendlyName)
        }
    }
    $ntfs = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Ntfs'; Id = 98; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue)
    $trim = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Microsoft-Windows-Defrag'; Id = 258; StartTime = (Get-Date).AddDays(-120) } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'retrim' })
    $w32 = @{}; foreach ($v in @(Get-CimInstance Win32_Volume -ErrorAction SilentlyContinue)) { if ($v.DriveLetter) { $w32[$v.DriveLetter.TrimEnd(':')] = $v } }
    $vols = foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter)) {
        $l = [string]$v.DriveLetter
        $ev = @($ntfs | Where-Object { $_.Message -match "\b${l}:" } | Sort-Object TimeCreated -Descending)
        $needs = $false; $since = $null
        if ($ev.Count -and $ev[0].Level -le 3) {
            $needs = $true
            $healthy = $ev | Where-Object { $_.Level -gt 3 } | Select-Object -First 1
            $bad = $ev | Where-Object { $_.Level -le 3 -and (-not $healthy -or $_.TimeCreated -gt $healthy.TimeCreated) }
            $since = ($bad | Sort-Object TimeCreated | Select-Object -First 1).TimeCreated
        }
        $lt = $trim | Where-Object { $_.Message -match "\(${l}:\)" } | Sort-Object TimeCreated -Descending | Select-Object -First 1
        [pscustomobject]@{
            Letter = $l; FS = [string]$v.FileSystem; SizeGB = [math]::Round($v.Size / 1GB, 1); FreeGB = [math]::Round($v.SizeRemaining / 1GB, 1)
            FreePct = $(if ($v.Size) { [math]::Round(100 * $v.SizeRemaining / $v.Size) } else { 0 }); Health = [string]$v.HealthStatus
            Dirty = $(if ($w32.ContainsKey($l)) { [bool]$w32[$l].DirtyBitSet } else { $false }); NeedsScan = $needs; ScanSince = $since; ScanEvents = @($ev | Where-Object { $_.Level -le 3 }).Count
            LastTrim = $(if ($lt) { $lt.TimeCreated } else { $null })
        }
    }
    $maint = $false
    try { $maint = ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' -ErrorAction Stop).MaintenanceDisabled -eq 1) } catch { }
    $trimOn = $null
    if ($admin) { $q = (& fsutil.exe behavior query DisableDeleteNotify 2>&1) -join ' '; if ($q -match 'NTFS DisableDeleteNotify\s*=\s*(\d)') { $trimOn = $matches[1] -eq '0' } }
    $perf = [bool](Get-CimClass -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk -ErrorAction SilentlyContinue)
    $busy = $null
    if ($perf) {
        try { $idle = foreach ($i in 1..3) { (Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter "Name='_Total'").PercentIdleTime; Start-Sleep -Milliseconds 600 }; $busy = [math]::Max(0, 100 - ($idle | Measure-Object -Average).Average) } catch { }
    }
    $shadow = $null; if ($admin) { $shadow = @(Get-CimInstance Win32_ShadowStorage -ErrorAction SilentlyContinue).Count -gt 0 }
    [pscustomobject]@{
        Disks = @($disks); Volumes = @($vols); MaintenanceDisabled = $maint; TrimEnabled = $trimOn; PerfCounters = $perf; Busy = $busy
        ShadowStorage = $shadow; PageFile = (Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Select-Object -First 1)
        SearchRunning = ((Get-Service WSearch -ErrorAction SilentlyContinue).Status -eq 'Running'); Admin = $admin
    }
}
function Get-DiskFindings($f) {
    $res = New-Object System.Collections.Generic.List[object]
    function Add-F([string]$sev, [string]$t, [string]$fix) { $res.Add([pscustomobject]@{ Sev = $sev; Title = $t; Fix = $fix }) }
    $ssd = @($f.Disks | Where-Object { $_.Media -eq 'SSD' -or $_.Bus -eq 'NVMe' }).Count -gt 0
    foreach ($d in $f.Disks) {
        if ($d.Health -and $d.Health -ne 'Healthy') { Add-F 'HIGH' "Disk $($d.Name) reports health '$($d.Health)'." 'Back up now; check the vendor tool for SMART details.' }
        if ($d.Errors -gt 0) { Add-F 'HIGH' "Disk $($d.Name) has $($d.Errors) uncorrected read/write errors." 'Back up now and check the drive with the vendor tool.' }
        if ($d.TempMax -ge 80) { Add-F 'WARN' "SSD $($d.Name) reached $($d.TempMax) °C (now $($d.Temp) °C). NVMe drives slow down at about 70-80 °C." 'Add a heatsink or airflow over the M.2 slot.' }
        if ($d.Dramless) { Add-F 'WARN' "$($d.Name) is an SSD without DRAM cache. Many small parallel writes (git, node_modules, builds in many worktrees) make it slow and push the disk to 100 %." 'Fewer parallel agents and worktrees; for heavy agent work a drive with DRAM cache is much faster.' }
    }
    foreach ($v in $f.Volumes) {
        if ($v.NeedsScan -or $v.Dirty) {
            $why = @(); if ($v.NeedsScan) { $why += "NTFS asks for a scan since $($v.ScanSince.ToString('dd.MM. HH:mm')) ($($v.ScanEvents)x)" }; if ($v.Dirty) { $why += 'dirty bit is set' }
            Add-F 'HIGH' "Drive $($v.Letter): has file system errors: $($why -join ', ')." 'overclock disk repair   (schedules chkdsk /spotfix; takes about a minute at the next restart)'
        }
        if ($v.FreePct -lt 10) { Add-F 'HIGH' "Drive $($v.Letter): only $($v.FreeGB) GB ($($v.FreePct) %) free." 'overclock disk   - see what fills it' } elseif ($v.FreePct -lt 15) { Add-F 'WARN' "Drive $($v.Letter): only $($v.FreeGB) GB ($($v.FreePct) %) free." 'overclock disk   - see what fills it' }
        if ($ssd -and $f.TrimEnabled -ne $false -and $v.FS -eq 'NTFS') {
            if (-not $v.LastTrim) { Add-F 'WARN' "No TRIM on drive $($v.Letter): in the last 120 days. Without TRIM an SSD gets slower over time." 'overclock disk repair   (runs TRIM once the file system is clean)' }
            elseif (((Get-Date) - $v.LastTrim).TotalDays -gt 14) { Add-F 'INFO' "Last TRIM on drive $($v.Letter): $([math]::Floor(((Get-Date) - $v.LastTrim).TotalDays)) days ago." 'overclock disk repair' }
        }
    }
    if ($f.TrimEnabled -eq $false) { Add-F 'WARN' 'TRIM is switched off for NTFS (DisableDeleteNotify = 1).' 'fsutil behavior set DisableDeleteNotify 0   (admin)' }
    if ($f.MaintenanceDisabled) { Add-F 'HIGH' 'Windows automatic maintenance is switched off: no file system scans, no TRIM, no cleanup ever run.' 'overclock disk repair   (turns it back on)' }
    if (-not $f.PerfCounters) {
        $off = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib' -ErrorAction SilentlyContinue).'Disable Performance Counters'
        $why = if ($off) { 'switched off: the registry value Perflib\"Disable Performance Counters" = 1 (set by a tuning tool) disables all of them' } else { 'broken' }
        Add-F 'WARN' "Windows performance counters are $($why): only Task Manager can see disk load, monitoring tools see nothing." 'overclock disk repair   (admin; turns them back on, no restart needed)'
    }
    if ($f.ShadowStorage -eq $false) { Add-F 'INFO' 'No shadow copy storage on any drive: online disk scans (chkdsk /scan) and restore points cannot run.' 'Turn on System Protection for C: (System Properties > System Protection), 5-10 % is enough.' }
    $res
}
function Get-FolderBytes([string]$p) {
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
    $it = Get-Item -LiteralPath $p -Force
    if ($it -is [IO.FileInfo]) { return [double]$it.Length }
    $o = & robocopy.exe $p 'C:\__overclock_nul__' /L /S /NJH /NFL /NDL /NC /BYTES /R:0 /W:0 /XJ 2>$null
    $line = $o | Select-String '^\s*Bytes\s*:' | Select-Object -First 1
    if ($line) { [double](($line.Line -split ':')[1].Trim() -split '\s+')[0] } else { $null }
}
function Get-WorktreeRoots {
    $f = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path $f)) { return @() }
    try { $j = Get-Content $f -Raw | ConvertFrom-Json } catch { return @() }
    if (-not $j.projects) { return @() }
    @($j.projects.PSObject.Properties.Name | Where-Object { $_ -match '[\\/]\.claude[\\/]worktrees[\\/]' } | ForEach-Object { (($_ -split '[\\/]\.claude[\\/]worktrees[\\/]')[0] -replace '/', '\') + '\.claude\worktrees' } | Sort-Object -Unique | Where-Object { Test-Path -LiteralPath $_ })
}
function Get-SpaceUsage {
    $goCache = "$env:LOCALAPPDATA\go-build"; $goMod = "$env:USERPROFILE\go\pkg\mod"
    if (Get-Command go -ErrorAction SilentlyContinue) { try { $goCache = (& go env GOCACHE).Trim(); $goMod = (& go env GOMODCACHE).Trim() } catch { } }
    $items = @(
        @('Docker / WSL disks', "$env:LOCALAPPDATA\Docker\wsl", 'docker system prune -a, then compact the .vhdx (diskpart compact vdisk)'),
        @('Go build cache', $goCache, 'go clean -cache'),
        @('Go module cache', $goMod, 'go clean -modcache'),
        @('npm cache', "$env:LOCALAPPDATA\npm-cache", 'npm cache clean --force'),
        @('pnpm store', "$env:LOCALAPPDATA\pnpm\store", 'pnpm store prune'),
        @('Yarn cache', "$env:LOCALAPPDATA\Yarn\Cache", 'yarn cache clean'),
        @('Bun cache', "$env:USERPROFILE\.bun\install\cache", 'bun pm cache rm'),
        @('pip cache', "$env:LOCALAPPDATA\pip\cache", 'pip cache purge'),
        @('Playwright browsers', "$env:LOCALAPPDATA\ms-playwright", 'npx playwright uninstall (old versions)'),
        @('Temp folder', $env:TEMP, 'Disk Cleanup / delete old files in %TEMP%'),
        @('Claude Code transcripts', (Join-Path $ClaudeHome 'projects'), 'cleanupPeriodDays in ~/.claude/settings.json'),
        @('claude-mem data', "$env:USERPROFILE\.claude-mem", 'see the claude-mem docs before deleting'),
        @('Claude desktop app data', "$env:APPDATA\Claude", '')
    )
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($i in $items) { $b = Get-FolderBytes $i[1]; if ($b -gt 50MB) { $res.Add([pscustomobject]@{ What = $i[0]; GB = [math]::Round($b / 1GB, 1); Path = $i[1]; Fix = $i[2]; Count = $null }) } }
    foreach ($r in Get-WorktreeRoots) {
        $n = @(Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue).Count
        if (-not $n) { continue }
        $b = Get-FolderBytes $r
        $res.Add([pscustomobject]@{ What = "Claude worktrees ($n)"; GB = [math]::Round($b / 1GB, 1); Path = $r; Fix = 'git worktree remove <path> for finished ones, then git worktree prune'; Count = $n })
    }
    $res
}
function Invoke-Disk {
    if ($Target -eq 'repair') { Invoke-DiskRepair; return }
    $sec = if ($Seconds) { $Seconds } else { 10 }
    if (-not (Test-Admin)) { Write-Warn2 'Not elevated: SSD temperature, TRIM state and shadow storage need an elevated PowerShell.' }
    Write-Host "Sampling disk I/O for $sec s ..." -ForegroundColor DarkGray
    $w = Measure-Window $sec
    $f = Get-DiskFacts
    $s = Get-Snap
    Write-Head '== Drives'
    foreach ($d in $f.Disks) {
        $t = if ($null -ne $d.Temp) { "  $($d.Temp) °C now, max $($d.TempMax) °C" } else { '' }
        $dr = if ($d.Dramless) { '  (no DRAM cache)' } else { '' }
        Write-Host ('{0}  {1} {2}, {3} GB, {4}{5}{6}' -f $d.Name, $d.Bus, $d.Media, $d.GB, $d.Health, $t, $dr)
    }
    foreach ($v in $f.Volumes) {
        $st = if ($v.NeedsScan -or $v.Dirty) { 'FILE SYSTEM ERRORS' } else { 'ok' }
        $tr = if ($v.LastTrim) { 'last TRIM ' + $v.LastTrim.ToString('dd.MM.yy') } else { 'no TRIM in 120 days' }
        $c = if ($st -ne 'ok') { 'Red' } else { 'Gray' }
        Write-Host ('  {0}:  {1,7:N1} GB free of {2,6:N0} GB ({3,2}%)   {4}   {5}' -f $v.Letter, $v.FreeGB, $v.SizeGB, $v.FreePct, $st, $tr) -ForegroundColor $c
    }
    $pm = if ($f.MaintenanceDisabled) { 'OFF' } else { 'on' }
    $pc = if ($f.PerfCounters) { 'ok' } else { 'BROKEN' }
    Write-Host ('Automatic maintenance: {0}   performance counters: {1}   Windows Search: {2}' -f $pm, $pc, $(if ($f.SearchRunning) { 'running' } else { 'off' }))
    if ($null -ne $f.Busy) { Write-Host ('Disk busy right now: {0:N0} %' -f $f.Busy) }
    if ($f.PageFile) { Write-Host ('Page file: {0:N0} MB in use (peak {1:N0} MB since boot)' -f $f.PageFile.CurrentUsage, $f.PageFile.PeakUsage) }

    Write-Head "== Who reads and writes ($sec s, files + pipes + network)"
    $own = @{}
    foreach ($r in $w.Rows) {
        $x = $s.ById[$r.Id]; if (-not $x) { continue }
        $o = if ($r.Id -eq 4) { 'System (Windows kernel, paging)' } else { Get-OwnerLabel $s $x }
        if (-not $own.ContainsKey($o)) { $own[$o] = [pscustomobject]@{ Owner = $o; R = 0.0; W = 0.0; Top = @{} } }
        $own[$o].R += $r.ReadMB; $own[$o].W += $r.WriteMB
        $k = $x.Name; $own[$o].Top[$k] = [double]$own[$o].Top[$k] + $r.ReadMB + $r.WriteMB
    }
    foreach ($e in ($own.Values | Sort-Object { $_.R + $_.W } -Descending | Select-Object -First 10)) {
        if ($e.R + $e.W -lt 0.5) { continue }
        $top = ($e.Top.Keys | Sort-Object { $e.Top[$_] } -Descending | Select-Object -First 3) -join ', '
        Write-Host ('{0,6:N1} MB/s read {1,6:N1} MB/s write  {2}  [{3}]' -f ($e.R / $sec), ($e.W / $sec), (Limit-Text $e.Owner 70), $top)
    }

    if (-not $NoSpace) {
        Write-Head '== What fills the disk (this can take a minute)'
        foreach ($u in (Get-SpaceUsage | Sort-Object GB -Descending)) {
            Write-Host ('{0,7:N1} GB  {1,-28} {2}' -f $u.GB, $u.What, (Hide-Paths $u.Path))
            if ($u.Fix) { Write-Host ('            -> ' + $u.Fix) -ForegroundColor DarkGray }
        }
    }

    Write-Head '== Findings'
    $fs = @(Get-DiskFindings $f)
    if (-not $fs.Count) { Write-Good 'No disk problems found.' }
    foreach ($sev in 'HIGH', 'WARN', 'INFO') {
        foreach ($x in $fs | Where-Object { $_.Sev -eq $sev }) {
            $c = switch ($sev) { 'HIGH' { 'Red' } 'WARN' { 'Yellow' } default { 'Gray' } }
            Write-Host ("[$sev] " + $x.Title) -ForegroundColor $c
            if ($x.Fix) { Write-Host ('       -> ' + $x.Fix) -ForegroundColor DarkGray }
        }
    }
}
function Invoke-DiskRepair {
    if (-not $DryRun) { Assert-Admin }
    $f = Get-DiskFacts
    $steps = 0
    function Step([string]$what, [scriptblock]$do) {
        $script:stepsDone++
        if ($DryRun) { Write-Host "[dry-run] would: $what" -ForegroundColor Yellow; return }
        if (-not (Confirm-Step $what)) { Write-Host '   skipped' -ForegroundColor DarkGray; return }
        try { & $do } catch { Write-Bad "   failed: $($_.Exception.Message)" }
    }
    $script:stepsDone = 0
    $broken = @($f.Volumes | Where-Object { $_.NeedsScan -or $_.Dirty })
    foreach ($v in $broken) {
        Step "Schedule a file system repair of $($v.Letter): (chkdsk /spotfix, runs at the next restart, about a minute)" {
            $o = (& cmd.exe /c "echo Y| chkdsk $($v.Letter): /spotfix" 2>&1) -join "`n"
            Write-Host ($o -split "`n" | Where-Object { $_ -match '\S' } | Select-Object -Last 3 | Out-String).Trim()
            Write-Warn2 '   Restart Windows to run it. Archive Claude sessions you do not need first: the desktop app resumes all of them.'
        }
    }
    if ($f.MaintenanceDisabled) {
        Step 'Turn Windows automatic maintenance back on (scans, TRIM, cleanup)' {
            Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance' -Name MaintenanceDisabled -ErrorAction Stop
            Write-Good '   Maintenance is on again.'
        }
    }
    if (-not $f.PerfCounters) {
        Step 'Turn the Windows performance counters back on (Perflib switch, lodctr /R, winmgmt /resyncperf)' {
            $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib'
            if ((Get-ItemProperty $pl -ErrorAction SilentlyContinue).'Disable Performance Counters') {
                # a tuning tool switched off ALL counters at once; this alone is the cause in most cases
                Set-ItemProperty $pl -Name 'Disable Performance Counters' -Value 0
                Write-Good '   Global switch "Disable Performance Counters" is off again.'
            }
            try { [void](Get-Counter '\PhysicalDisk(_Total)\% Disk Time' -ErrorAction Stop); $ok = $true } catch { $ok = $false }
            if (-not $ok) {
                & "$env:WINDIR\System32\lodctr.exe" /R | Out-Null
                if (Test-Path "$env:WINDIR\SysWOW64\lodctr.exe") { & "$env:WINDIR\SysWOW64\lodctr.exe" /R | Out-Null }
            }
            & "$env:WINDIR\System32\wbem\winmgmt.exe" /resyncperf | Out-Null
            Start-Sleep -Seconds 3
            if (Get-CimClass -ClassName Win32_PerfRawData_PerfDisk_PhysicalDisk -ErrorAction SilentlyContinue) { Write-Good '   Performance counters are back.' } else { Write-Warn2 '   Not visible yet; they usually appear after a restart.' }
        }
    }
    $ssdVols = @($f.Volumes | Where-Object { $_.FS -eq 'NTFS' -and (-not $_.LastTrim -or ((Get-Date) - $_.LastTrim).TotalDays -gt 14) })
    if ($ssdVols.Count -and @($f.Disks | Where-Object { $_.Media -eq 'SSD' -or $_.Bus -eq 'NVMe' }).Count) {
        if ($broken.Count) {
            Write-Warn2 'TRIM is postponed: it must not run while the file system has errors (it could release blocks that are still in use). Run "disk repair" again after the restart.'
        } else {
            foreach ($v in $ssdVols) { Step "Run TRIM on $($v.Letter): (Optimize-Volume -ReTrim, a few minutes, safe to keep working)" { Optimize-Volume -DriveLetter $v.Letter -ReTrim -Verbose; Write-Good "   TRIM on $($v.Letter): done." } }
        }
    }
    if (-not $script:stepsDone -and -not $broken.Count) { Write-Good 'Nothing to repair.' }
}

# ---------------------------------------------------------------- throttle
function Set-ClaudePriority($s, $ids, [bool]$undo) {
    $want = if ($undo) { [Diagnostics.ProcessPriorityClass]::Normal } else { [Diagnostics.ProcessPriorityClass]::BelowNormal }
    $from = if ($undo) { [Diagnostics.ProcessPriorityClass]::BelowNormal } else { [Diagnostics.ProcessPriorityClass]::Normal }
    # disk: background I/O priority (1), so your own reads and writes are served first; undo sets it back to normal (2)
    $ioWant = if ($undo) { 2 } else { 1 }; $ioFrom = if ($undo) { 1 } else { 2 }
    $done = 0; $skipped = 0; $io = 0
    foreach ($id in $ids) {
        if ($id -eq $PID) { continue }
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            $x = $s.ById[$id]
            if ($x -and [math]::Abs(($p.StartTime - $x.Created).TotalSeconds) -gt 1) { $skipped++; continue }
            if ($p.PriorityClass -eq $from) { $p.PriorityClass = $want; $done++ } else { $skipped++ }
            if ([Overclock.Native]::SetIoPriority($id, $ioWant, $ioFrom) -eq $ioFrom) { $io++ }
        } catch { $skipped++ }
    }
    @($done, $skipped, $io)
}
function Invoke-Throttle {
    $s = Get-Snap
    $ids = New-Object System.Collections.Generic.HashSet[int]
    foreach ($x in $s.List) { if ($x.Kind -eq 'cli' -or $x.Cli) { [void]$ids.Add($x.Id) } }
    foreach ($o in Get-Orphans $s) { if (-not $o.Expected) { foreach ($t in $o.Tree) { [void]$ids.Add($t.Id) } } }
    $r = Set-ClaudePriority $s $ids ([bool]$Undo)
    $done = $r[0]; $skipped = $r[1]; $io = $r[2]
    if ($Undo) { Write-Good "$done Claude processes are back at normal CPU priority, $io at normal disk priority." }
    else {
        Write-Good "$done Claude processes now run below normal CPU priority, $io at background disk priority; your own apps come first."
        Write-Host 'Builds, tests and agents keep running and use the CPU you are not using. Processes they start inherit the lower priority.' -ForegroundColor DarkGray
        Write-Host 'New sessions start at normal priority: run "throttle" again after opening new ones. Undo with: throttle -Undo' -ForegroundColor DarkGray
    }
    if ($skipped) { Write-Host "$skipped processes left as they were (already changed, exited or protected)." -ForegroundColor DarkGray }
}

# ---------------------------------------------------------------- autopilot
function Get-ProcKey($x) { "$($x.Id)|$($x.Created.ToString('yyyyMMddHHmmss'))" }
function Get-AutopilotState {
    $name = "autopilot-$env:USERNAME"
    $t = Get-ScheduledTask -TaskPath $TaskPath -TaskName $name -ErrorAction SilentlyContinue
    $beat = Join-Path $ApDir 'autopilot.last'
    $last = $null; $info = ''
    if (Test-Path $beat) { $last = (Get-Item $beat).LastWriteTime; $info = (Get-Content $beat -Raw).Trim() }
    $every = 10
    if ($t) { try { $iv = $t.Triggers[0].Repetition.Interval; if ($iv -match 'PT(\d+)M') { $every = [int]$matches[1] } } catch { } }
    $installed = Test-Path (Join-Path $ApDir 'autopilot.vbs')
    $state = if (-not $t -and -not $installed) { 'off' } elseif (-not $t) { 'TASK MISSING' } elseif (-not $last) { 'never ran' } elseif (((Get-Date) - $last).TotalMinutes -gt 3 * $every + 2) { 'STALE' } else { 'ok' }
    [pscustomobject]@{ State = $state; Every = $every; LastRun = $last; Info = $info; Name = $name }
}
function Invoke-AutopilotRun {
    New-Item -ItemType Directory -Force -Path $ApDir | Out-Null
    $log = Join-Path $ApDir 'autopilot.log'; $knownFile = Join-Path $ApDir 'autopilot-known.json'
    $minAge = if ($PSBoundParameters.ContainsKey('MinAgeMinutes') -or $script:MinAgeBound) { $MinAgeMinutes } else { 30 }
    $s = Get-Snap
    $known = New-Object System.Collections.Generic.HashSet[string]
    if (Test-Path $knownFile) { try { foreach ($k in (Get-Content $knownFile -Raw | ConvertFrom-Json)) { [void]$known.Add([string]$k) } } catch { } }
    $keep = New-Object System.Collections.Generic.HashSet[string]
    $ids = New-Object System.Collections.Generic.HashSet[int]
    foreach ($x in $s.List) { if ($x.Kind -eq 'cli' -or $x.Cli) { [void]$keep.Add((Get-ProcKey $x)); [void]$ids.Add($x.Id) } }
    $reaped = New-Object System.Collections.Generic.List[string]
    foreach ($o in Get-Orphans $s) {
        if ($o.Expected) { continue }
        # only trees this autopilot saw inside a Claude session before; your own detached servers are never touched
        $fromClaude = @($o.Tree | Where-Object { $known.Contains((Get-ProcKey $_)) }).Count -gt 0
        if (-not $fromClaude) { continue }
        if (((Get-Date) - $o.Root.Created).TotalMinutes -lt $minAge) {
            foreach ($t in $o.Tree) { [void]$keep.Add((Get-ProcKey $t)); [void]$ids.Add($t.Id) }
            continue
        }
        $what = $o.Tree | Where-Object { $_.Name -notmatch '^(bash|sh|cmd|conhost)\.exe$' } | Select-Object -First 1
        if (-not $what) { $what = $o.Root }
        if (Stop-OrphanTree $o) { $reaped.Add(('ended pid {0} ({1} proc, {2}, age {3}): {4}' -f $o.Root.Id, $o.Count, (Format-MB $o.MB), (Format-Age $o.Root.Created), (Limit-Text (Hide-Paths "$($what.Name) $($what.Cmd -replace '^"?[^"]*\\', '')") 110))) }
        else { foreach ($t in $o.Tree) { [void]$keep.Add((Get-ProcKey $t)) } }
    }
    # language servers that did nothing since the last run and are older than minAge: end them, Claude Code restarts them on demand
    $lspFile = Join-Path $ApDir 'autopilot-lsp.json'
    $lspPrev = @{}
    if (Test-Path $lspFile) { try { (Get-Content $lspFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $lspPrev[$_.Name] = [double]$_.Value } } catch { } }
    $lspNow = @{}
    foreach ($l in Get-LspTrees $s) {
        $k = Get-ProcKey $l.Root
        $idle = $lspPrev.ContainsKey($k) -and ($l.Cpu - $lspPrev[$k]) -lt 1
        if ($idle -and ((Get-Date) - $l.Root.Created).TotalMinutes -ge $minAge -and $l.MB -ge 200 -and (Stop-OrphanTree $l)) {
            $reaped.Add(('ended idle language server {0} (pid {1}, {2}, session pid {3}); Claude Code starts it again when needed' -f $l.Name, $l.Root.Id, (Format-MB $l.MB), $l.Cli))
            foreach ($t in $l.Tree) { [void]$ids.Remove($t.Id) }
        } else { $lspNow[$k] = $l.Cpu }
    }
    $lspNow | ConvertTo-Json -Compress | Set-Content -Path $lspFile -Encoding UTF8
    $pr = Set-ClaudePriority $s $ids $false
    @($keep) | ConvertTo-Json -Compress | Set-Content -Path $knownFile -Encoding UTF8
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.old" -Force }
    foreach ($r in $reaped) { Add-Content -Path $log -Value "$stamp  $r" }
    if ($pr[0] -or $pr[2]) { Add-Content -Path $log -Value "$stamp  lowered CPU priority of $($pr[0]), disk priority of $($pr[2]) Claude process(es)" }
    $sess = @($s.List | Where-Object { $_.Role -eq 'session' }).Count
    Set-Content -Path (Join-Path $ApDir 'autopilot.last') -Value ("{0}  sessions={1}  ended={2}  lowered={3}  watching={4}" -f $stamp, $sess, $reaped.Count, $pr[0], $keep.Count)
}
function Invoke-Autopilot {
    switch ($Target) {
        'run' { Invoke-AutopilotRun }
        'install' {
            $every = if ($PSBoundParameters.ContainsKey('Every') -or $script:EveryBound) { $Every } else { 10 }
            $minAge = if ($script:MinAgeBound) { $MinAgeMinutes } else { 30 }
            New-Item -ItemType Directory -Force -Path $ApDir | Out-Null
            Copy-Item -LiteralPath (Join-Path $ScriptDir 'overclock.ps1') -Destination $ApDir -Force
            $ki = Join-Path $ScriptDir 'known-issues.json'; if (Test-Path $ki) { Copy-Item -LiteralPath $ki -Destination $ApDir -Force }
            $ps = Join-Path $ApDir 'overclock.ps1'
            # wscript keeps the run invisible; a hidden PowerShell window would still flash every few minutes
            $vbs = Join-Path $ApDir 'autopilot.vbs'
            ('CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{0}"" autopilot run -MinAgeMinutes {1}", 0, True' -f $ps, $minAge) | Set-Content -Path $vbs -Encoding ASCII
            $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
            $t1 = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $every)
            $t2 = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            $lvl = if (Test-Admin) { 'Highest' } else { 'Limited' }
            $pr = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel $lvl
            $st = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            $name = "autopilot-$env:USERNAME"
            Register-ScheduledTask -TaskPath $TaskPath -TaskName $name -Action $action -Trigger $t1, $t2 -Principal $pr -Settings $st -Description "claude-overclock autopilot: every $every min ends orphaned Claude process trees older than $minAge min and keeps Claude at below-normal priority." -Force | Out-Null
            $beat = Join-Path $ApDir 'autopilot.last'
            if (Test-Path $beat) { Remove-Item $beat -Force }
            Start-ScheduledTask -TaskPath $TaskPath -TaskName $name
            for ($i = 0; $i -lt 90 -and -not (Test-Path $beat); $i++) { Start-Sleep -Seconds 1 }
            Write-Good "Autopilot installed: every $every min it ends orphaned Claude trees older than $minAge min and keeps Claude sessions at below-normal priority."
            Write-Host '   It only ends processes it saw inside a Claude session before, never your own programs.'
            if (Test-Path $beat) { Write-Host ('   first run: ' + (Get-Content $beat -Raw).Trim()) } else { Write-Warn2 '   The first run has not reported back yet; check "autopilot status" in a minute.' }
            Write-Host '   status: overclock autopilot status    off: overclock autopilot remove' -ForegroundColor DarkGray
        }
        'remove' {
            $name = "autopilot-$env:USERNAME"
            Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            if (Test-Path $ApDir) { Remove-Item $ApDir -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Good 'Autopilot removed. Priorities already lowered stay until those processes end (or run throttle -Undo).'
        }
        default {
            $a = Get-AutopilotState
            $c = switch ($a.State) { 'ok' { 'Green' } 'off' { 'Gray' } default { 'Red' } }
            Write-Host ('Autopilot: {0}   every {1} min   last run: {2}' -f $a.State, $a.Every, $a.Info) -ForegroundColor $c
            $log = Join-Path $ApDir 'autopilot.log'
            if (Test-Path $log) { Get-Content $log -Tail 8 | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray } }
            if ($a.State -eq 'off') { Write-Host 'Turn it on with: overclock autopilot install' }
            if ($a.State -eq 'TASK MISSING') { Write-Warn2 'The scheduled task is gone but its files are still here. Something deleted it; reinstall with "autopilot install".' }
        }
    }
}

# ---------------------------------------------------------------- report
function Invoke-Report {
    $r = Invoke-Check $(if ($Seconds) { $Seconds } else { 30 })
    $s = $r.Snap
    $projects = @{}
    function Hide-Project([string]$p) { if (-not $p) { return '' }; if (-not $projects.ContainsKey($p)) { $projects[$p] = 'project-' + [char](65 + $projects.Count) }; $projects[$p] }
    $cpu = ([string](Get-CimInstance Win32_Processor | Select-Object -First 1).Name).Trim()
    $os = Get-CimInstance Win32_OperatingSystem
    $cc = @($s.List | Where-Object { $_.Kind -eq 'cli' -and $_.Path -match 'claude-code\\([\d.]+)' } | ForEach-Object { $matches[1] } | Sort-Object -Unique) -join ', '
    $appv = @($s.List | Where-Object { $_.Kind -eq 'app' -and $_.Path -match 'app-([\d.]+)' } | ForEach-Object { $matches[1] } | Sort-Object -Unique) -join ', '
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('## overclock report'); $L.Add('')
    $L.Add("- overclock $Version, $($os.Caption) build $($os.BuildNumber)"); $L.Add("- CPU: $cpu ($Cores threads), RAM: $(Format-MB ($os.TotalVisibleMemorySize / 1KB))")
    $L.Add("- Claude desktop app: $appv   Claude Code: $cc")
    $L.Add(('- RAM {0}% used, commit {1}%, {2:N0} processes, {3:N0} handles, up {4}' -f $r.RamPct, $r.CommitPct, $s.List.Count, $r.Handles, (Format-Age $os.LastBootUpTime)))
    $L.Add(''); $L.Add('### Findings'); $L.Add('')
    foreach ($f in $r.Findings) { $L.Add("- **$($f.Sev)** $(Hide-Paths $f.Title) -> $(Hide-Paths $f.Fix)") }
    $cap = [double]$r.Window.Seconds * $Cores
    $L.Add(''); $L.Add('### CPU and RAM by owner'); $L.Add(''); $L.Add('| Owner | Processes | CPU | RAM |'); $L.Add('|---|---|---|---|')
    foreach ($e in ($r.Owners | Sort-Object MB -Descending | Select-Object -First 12)) {
        $o = $e.Owner
        if ($o -match '^Claude session (\w+) (.+)$') { $o = "Claude session $($matches[1]) $(Hide-Project $matches[2])" }
        $L.Add(('| {0} | {1} | {2:N1} % | {3} |' -f $o, $e.N, (100 * $e.Cpu / $cap), (Format-MB $e.MB)))
    }
    $L.Add(''); $L.Add('### Handle growth'); $L.Add(''); $L.Add('| Process | Service | Handles | per hour |'); $L.Add('|---|---|---|---|')
    foreach ($x in ($r.Leaks | Sort-Object Handles -Descending | Select-Object -First 8)) { $L.Add(('| {0} | {1} | {2:N0} | {3:N0} |' -f $x.Name, $x.Service, $x.Handles, $x.PerHour)) }
    $L.Add(''); $L.Add('### Agents (last hour)'); $L.Add('')
    $a = $r.Activity
    $L.Add("- $($a.Sessions) sessions active, $($a.Subagents) subagents started, peak $($a.Peak) agents at once, $($a.Running.Count) workflow(s) running")
    $mcpGroups = $s.List | Where-Object { $_.Role -eq 'mcp' } | Group-Object { Get-Label $_ } | Sort-Object Count -Descending
    foreach ($g in $mcpGroups) { $L.Add("- MCP server ``$($g.Name)``: $($g.Count) copies") }
    $bt = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue | Where-Object { $_.DeviceClass -eq 'Bluetooth' -and $_.Manufacturer -notmatch 'Microsoft' } | Select-Object -First 3
    if ($bt) { $L.Add(''); $L.Add('### Bluetooth drivers'); $L.Add(''); foreach ($b in $bt) { $L.Add("- $($b.DeviceName) - $($b.Manufacturer) - $($b.DriverVersion)") } }
    $out = Join-Path (Get-Location).Path 'overclock-report.md'
    $L | Set-Content -Path $out -Encoding UTF8
    Write-Host ''
    Write-Good "Report written: $out"
    Write-Host "It contains no user names, paths or project names. Paste it into: $RepoUrl/issues/new"
}

switch ($Command) {
    'check' { $null = Invoke-Check $(if ($Seconds) { $Seconds } else { 20 }) }
    'sessions' { Invoke-Sessions }
    'agents' { Invoke-Agents }
    'leaks' { Invoke-Leaks }
    'handles' { Invoke-Handles }
    'spawns' { Invoke-Spawns }
    'orphans' { Invoke-Orphans }
    'reap' { Invoke-Orphans }
    'disk' { Invoke-Disk }
    'throttle' { Invoke-Throttle }
    'autopilot' { Invoke-Autopilot }
    'watchdog' { Invoke-Watchdog }
    'report' { Invoke-Report }
    'help' { Get-Help $MyInvocation.MyCommand.Path -Detailed }
}
