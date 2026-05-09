#ps1
# edr-cloudlab Windows lab — outer cloudbase-init wrapper.
#
# Cloudbase-init runs in SYSTEM context very early in boot, when many
# Windows services (Windows Update, BITS, TrustedInstaller, msiserver) are
# not yet running. Tailscale's MSI returns 1603 and Add-WindowsCapability
# hangs for an hour waiting on wuauserv.
#
# We sidestep both by:
#   1) Enabling RDP immediately (so the operator always has emergency access)
#   2) Writing the real bootstrap script to C:\edr-inner.ps1
#   3) Registering a scheduled task that runs it ~3 min from now, by which
#      time Windows is fully up.
# The outer then exits and cloudbase-init returns cleanly.

$ErrorActionPreference = "Continue"

# (1) RDP — emergency access, before anything else.
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -ErrorAction Continue
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction Continue

"$(Get-Date -Format o) outer wrapper start user=$env:USERNAME pid=$PID" | Out-File -FilePath C:\edr-outer.log -Append

# (2) Decode inner from base64 and write to disk.
$inner = "C:\edr-inner.ps1"
$b64   = "${inner_b64}"
$bytes = [Convert]::FromBase64String($b64)
$text  = [Text.Encoding]::UTF8.GetString($bytes)
[IO.File]::WriteAllText($inner, $text, (New-Object Text.UTF8Encoding($false)))
"$(Get-Date -Format o) inner written ($($bytes.Length) bytes) to $inner" | Out-File -FilePath C:\edr-outer.log -Append

# (3) Schedule the inner to run in ~3 minutes as SYSTEM with highest privileges.
$argString = "-NoProfile -ExecutionPolicy Bypass -File `"$inner`""
$action    = New-ScheduledTaskAction    -Execute "powershell.exe" -Argument $argString
$trigger   = New-ScheduledTaskTrigger   -Once -At ((Get-Date).AddMinutes(3))
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
Register-ScheduledTask -TaskName "edr-cloudlab-bootstrap" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
"$(Get-Date -Format o) scheduled task registered to fire at $((Get-Date).AddMinutes(3).ToString('o'))" | Out-File -FilePath C:\edr-outer.log -Append
