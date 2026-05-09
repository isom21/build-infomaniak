# edr-cloudlab Windows lab — inner bootstrap script.
# Delivered by the outer wrapper, registered as a scheduled task that fires
# ~3 min after first boot (so Windows Update / BITS / TrustedInstaller /
# msiserver are warm and Add-WindowsCapability + Tailscale MSI both work).

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$log = "C:\edr-bootstrap.log"
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

# Resilience: keep the system daemon authenticated across interactive user logins.
# Without these, the Tailscale GUI tray app can deauthenticate the unattended
# session on first user RDP login and the device drops off the tailnet.
Step "Tailscale: pin UnattendedMode in registry" {
    if (-not (Test-Path 'HKLM:\SOFTWARE\Tailscale IPN')) {
        New-Item -Path 'HKLM:\SOFTWARE\Tailscale IPN' -Force | Out-Null
    }
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Tailscale IPN' -Name 'UnattendedMode' -Value 'always' -Force
    L "  UnattendedMode: $((Get-ItemProperty 'HKLM:\SOFTWARE\Tailscale IPN' 'UnattendedMode' -ErrorAction Continue).UnattendedMode)"
}
Step "Tailscale: disable GUI tray auto-start" {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Tailscale-IPN' -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Run' -Name 'Tailscale-IPN' -Force -ErrorAction SilentlyContinue
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
    $sshDir   = "C:\ProgramData\ssh"
    $authFile = Join-Path $sshDir "administrators_authorized_keys"
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    [System.IO.File]::WriteAllText($authFile, $authKeys, (New-Object System.Text.UTF8Encoding $false))
    # Required ACL: only SYSTEM + Administrators may read; OpenSSH refuses otherwise.
    icacls.exe $authFile /inheritance:r 2>&1 | Out-Null
    icacls.exe $authFile /grant 'Administrators:F' /grant 'SYSTEM:F' 2>&1 | Out-Null
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
