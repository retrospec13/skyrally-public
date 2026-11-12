# Close ONLY this lane's own Studio window: the pid recorded by run_skyrally.ps1, verified by process name and title.
param([string]$Root, [string]$Name)
$pidFile = Join-Path $Root "out\owned_pid.txt"
if (-not (Test-Path $pidFile)) { Write-Output "NO_PIDFILE"; exit 0 }
$old = (Get-Content $pidFile | Select-Object -First 1).Trim()
if ($old -notmatch '^\d+$') { Write-Output "BAD_PID"; exit 0 }
# An SSH session cannot read window titles, so ownership is proved by the process command line (the place file it opened).
$p = Get-CimInstance Win32_Process -Filter "ProcessId=$old" -ErrorAction SilentlyContinue
if ($p -and $p.Name -eq "RobloxStudioBeta.exe" -and $p.CommandLine -like "*\$Name.rbxlx*") {
  Stop-Process -Id $p.ProcessId -Force
  Write-Output "CLOSED pid=$($p.ProcessId) cmd='$($p.CommandLine)'"
} else { Write-Output "NOT_RUNNING_OR_NOT_OURS pid=$old" }
