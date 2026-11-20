param(
  [Parameter(Mandatory = $true)][string]$StateDir,
  [Parameter(Mandatory = $true)][string]$AssetDir,
  [Parameter(Mandatory = $true)][string]$PrefsFile
)

# Starts the Claude-chan window on its own, outside the Claude Code session that asks for it.
# The desktop app stops a session's process when you switch to Chat or leave the session idle,
# and a window started as that process's child would go with it. This one lives as long as the
# Claude app itself. Prints "running" when a window is already up, "started" otherwise.

$ErrorActionPreference = 'Stop'

$existing = $null
if ([System.Threading.Mutex]::TryOpenExisting('Local\ClaudePetCompanion', [ref]$existing)) {
  $existing.Dispose()
  'running'
  exit 0
}

# the app Claude Code runs in: the first ancestor process with a main window
$hostPid = 0
$p = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId
for ($i = 0; $i -lt 10 -and $p -gt 4; $i++) {
  $gp = Get-Process -Id $p -ErrorAction SilentlyContinue
  if ($gp -and $gp.MainWindowHandle -ne [IntPtr]::Zero) { $hostPid = $p; break }
  $w = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
  if (-not $w) { break }
  $p = [int]$w.ParentProcessId
}

$script = Join-Path $PSScriptRoot 'pet-window.ps1'
$q = { param($s) '"' + ($s -replace '"', '') + '"' }
$cmd = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ' +
  (& $q $script) + ' -StateDir ' + (& $q $StateDir) + ' -AssetDir ' + (& $q $AssetDir) +
  ' -PrefsFile ' + (& $q $PrefsFile) + ' -HostPid ' + $hostPid

# created through WMI, so it is nobody's child and no session's ending takes it down
$startup = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
$r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
  CommandLine = $cmd
  ProcessStartupInformation = $startup
}
if ($r.ReturnValue -ne 0) { "failed $($r.ReturnValue)"; exit 1 }
'started'
