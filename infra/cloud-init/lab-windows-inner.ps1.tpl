# edr-cloudlab Windows lab — inner bootstrap script.
# Delivered by the outer wrapper, registered as a scheduled task that fires
# ~3 min after first boot (so Windows Update / BITS / TrustedInstaller /
# msiserver are warm and Add-WindowsCapability + Tailscale MSI both work).

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$log    = "C:\edr-bootstrap.log"
$labDir = "C:\ProgramData\edr-cloudlab"
function L($m) { "$(Get-Date -Format o) $m" | Add-Content -Path $log }
function Step($name, $block) {
    L ">>> $name"
    try {
        & $block
        L "<<< OK $name"
    } catch {
        L "!!! $name FAILED: $($_.Exception.Message)"
    }
}
# OpenSSH refuses to read administrators_authorized_keys (and we don't want a
# plaintext auth key) unless ACLs are SYSTEM+Administrators only.
function Write-SecureFile($path, $content) {
    $dir = Split-Path $path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding $false))
    icacls.exe $path /inheritance:r 2>&1 | Out-Null
    icacls.exe $path /grant 'SYSTEM:F' /grant 'Administrators:F' 2>&1 | Out-Null
}

L "=== inner bootstrap (deferred) START ==="
L "PS $($PSVersionTable.PSVersion)  64bit=$([Environment]::Is64BitProcess)  user=$env:USERNAME"
L "boot time: $((Get-CimInstance Win32_OperatingSystem).LastBootUpTime)"

# 0) Make sure the services Add-WindowsCapability and msiexec depend on are up.
Step "ensure update services" {
    foreach ($svc in @('msiserver','BITS','wuauserv','TrustedInstaller')) {
        try { Start-Service $svc -ErrorAction Stop } catch { }
        L "  $svc : $((Get-Service $svc -ErrorAction Continue).Status)"
    }
}

# 1) Tailscale via direct MSI (the web-stub EXE returns 1603 from SYSTEM ctx)
Step "Tailscale: download MSI" {
    $msi = "$env:TEMP\tailscale.msi"
    Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi" -OutFile $msi -UseBasicParsing -TimeoutSec 180
    L "  $((Get-Item $msi).Length) bytes downloaded"
}
Step "Tailscale: msiexec install" {
    $msi = "$env:TEMP\tailscale.msi"
    $mlog = "$env:TEMP\tailscale-msi.log"
    $args = @("/i", $msi, "/quiet", "/norestart", "/L*v", $mlog, "TS_UNATTENDEDMODE=always", "TS_NOLAUNCH=true")
    $p = Start-Process msiexec.exe -ArgumentList $args -Wait -PassThru
    L "  msiexec exit=$($p.ExitCode)  log=$mlog"
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010 -and (Test-Path $mlog)) {
        L "  -- last 30 lines of MSI log --"
        Get-Content $mlog -Tail 30 | ForEach-Object { L "  | $_" }
    }
}
Step "Tailscale: ensure service" {
    Start-Service Tailscale -ErrorAction Continue
    Start-Sleep 3
    L "  service: $((Get-Service Tailscale -ErrorAction Continue).Status)"
}
Step "Tailscale: up" {
    $tsExe = "C:\Program Files\Tailscale\tailscale.exe"
    if (-not (Test-Path $tsExe)) { throw "tailscale.exe not present post-install" }
    & $tsExe up --auth-key="${ts_authkey}" --hostname=lab-windows --advertise-tags=tag:lab-windows --unattended 2>&1 | ForEach-Object { L "  up: $_" }
    Start-Sleep 5
    & $tsExe status 2>&1 | ForEach-Object { L "  status: $_" }
}

# Self-healing: a scheduled task runs every 5 min, checks tailscaled state,
# re-runs `tailscale up` if BackendState != Running. Defends against the
# Windows Tailscale GUI tray's habit of deauthenticating the unattended
# session on interactive user logins.
Step "Tailscale: persist auth key for self-healing" {
    $keyFile = Join-Path $labDir "ts-authkey"
    Write-SecureFile $keyFile "${ts_authkey}"
    L "  $keyFile (SYSTEM+Administrators only)"
}

Step "Tailscale: install self-healing script" {
    $heal = Join-Path $labDir "ts-heal.ps1"
    # NOTE: heredoc is single-quoted, so PS vars inside don't expand here.
    # Tailscale `up` args (hostname/tag) are duplicated from the bootstrap
    # invocation above — keep them in sync if either changes.
    $script = @'
$ErrorActionPreference = "Continue"
$ts  = "C:\Program Files\Tailscale\tailscale.exe"
$log = "C:\ProgramData\edr-cloudlab\ts-heal.log"
if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) {
    Move-Item -Path $log -Destination "$log.1" -Force -ErrorAction SilentlyContinue
}
function L($m) { "$(Get-Date -Format o) $m" | Add-Content $log }
if (-not (Test-Path $ts)) { L "tailscale.exe missing"; exit 1 }
$raw   = & $ts status --json 2>$null
$state = if ($raw -match '"BackendState"\s*:\s*"([^"]+)"') { $Matches[1] } else { "Unknown" }
if ($state -eq "Running") { exit 0 }
$key = (Get-Content "C:\ProgramData\edr-cloudlab\ts-authkey" -Raw).Trim()
L "BackendState=$state, re-running up"
$out = & $ts up --auth-key=$key --hostname=lab-windows --advertise-tags=tag:lab-windows --unattended 2>&1
L "up result: $out"
'@
    Set-Content -Path $heal -Value $script -Encoding UTF8
    L "  $heal"
}

Step "Tailscale: register self-healing scheduled task (5-min interval)" {
    $heal = Join-Path $labDir "ts-heal.ps1"
    $action    = New-ScheduledTaskAction    -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$heal`""
    $trigger   = New-ScheduledTaskTrigger   -Once -At ((Get-Date).AddMinutes(2)) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
    Register-ScheduledTask -TaskName "edr-cloudlab-ts-heal" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    L "  scheduled task: edr-cloudlab-ts-heal (every 5 min as SYSTEM)"
}

Step "Tailscale: pin UnattendedMode + disable GUI everywhere" {
    if (-not (Test-Path 'HKLM:\SOFTWARE\Tailscale IPN')) {
        New-Item -Path 'HKLM:\SOFTWARE\Tailscale IPN' -Force | Out-Null
    }
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Tailscale IPN' -Name 'UnattendedMode' -Value 'always' -Force
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Tailscale-IPN' -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run' -Name 'Tailscale-IPN' -Force -ErrorAction SilentlyContinue
    # Disable Tailscale-installed scheduled tasks (logon-triggered GUI launchers); our heal task is exempt.
    Get-ScheduledTask -TaskName 'Tailscale*' -ErrorAction SilentlyContinue |
        Where-Object TaskName -ne 'edr-cloudlab-ts-heal' |
        ForEach-Object {
            Disable-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction Continue | Out-Null
            L "  disabled task: $($_.TaskPath)$($_.TaskName)"
        }
}

# 2) OpenSSH — should now work since update services are running
Step "OpenSSH: install capability" {
    $cap = Get-WindowsCapability -Online | Where-Object Name -like "OpenSSH.Server*"
    if ($cap.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }
    L "  state: $((Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*').State)"
}
Step "OpenSSH: service + firewall" {
    Set-Service -Name sshd -StartupType Automatic -ErrorAction Continue
    Start-Service sshd -ErrorAction Continue
    New-NetFirewallRule -Name sshd -DisplayName "OpenSSH SSH Server" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction SilentlyContinue | Out-Null
    L "  sshd: $((Get-Service sshd -ErrorAction Continue).Status)"
}

# Install Administrator's authorized_keys so SSH works without password
# from any host that has the matching private key.
# Reference: https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement#administrative-user
Step "OpenSSH: install Administrator authorized_keys" {
    $authKeys = @"
${ssh_pubkeys}
"@
    $authFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    Write-SecureFile $authFile $authKeys
    L "  authorized_keys: $((Get-Item $authFile).Length) bytes, $($authKeys.Trim().Split([Environment]::NewLine).Count) keys"
}

# 3) Kernel driver test environment (effective after next reboot)
Step "test-signing enable" {
    bcdedit /set testsigning on | ForEach-Object { L "  $_" }
}

# 4) kdnet — populate dev-host tailnet IP after dev is up, then uncomment & redeploy
# $devIP = "100.84.73.94"
# Step "kdnet enable" {
#     bcdedit /dbgsettings net hostip:$devIP port:50000 key:edr.kdnet.windbg.test | ForEach-Object { L "  $_" }
#     bcdedit /debug on | ForEach-Object { L "  $_" }
# }

"$(Get-Date -Format o)" | Set-Content -Path C:\edr-bootstrap-complete
L "=== inner bootstrap END ==="
