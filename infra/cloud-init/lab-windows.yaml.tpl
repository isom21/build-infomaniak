#ps1
# `#ps1` MUST be line 1. It dispatches to plain `powershell.exe` (works for
# both 32- and 64-bit cloudbase-init). The `#ps1_sysnative` variant only
# works from 32-bit cloudbase-init and silently hangs otherwise.

$ErrorActionPreference = "Continue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$log = "C:\edr-bootstrap.log"
function L($m) { "$(Get-Date -Format o) $m" | Add-Content $log }

L "=== START ==="
L "PS $($PSVersionTable.PSVersion)"

# Enable OpenSSH Server (debug ingress; SG also needs TCP/22 open)
L "OpenSSH: install"
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Continue | Out-Null
L "OpenSSH: start service"
Set-Service sshd -StartupType Automatic -ErrorAction Continue
Start-Service sshd -ErrorAction Continue
L "OpenSSH: firewall"
New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH SSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 -ErrorAction Continue | Out-Null
L "OpenSSH status: $((Get-Service sshd -ErrorAction Continue).Status)"

# Install Tailscale
$msi = "$env:TEMP\ts.msi"
L "Tailscale: download MSI"
try {
  Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest-amd64.msi" -OutFile $msi -UseBasicParsing -TimeoutSec 120
  L "Tailscale: downloaded $((Get-Item $msi).Length) bytes"
} catch {
  L "Tailscale: download FAILED: $($_.Exception.Message)"
}

L "Tailscale: install MSI"
$proc = Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart" -Wait -PassThru -ErrorAction Continue
L "Tailscale: msiexec exit=$($proc.ExitCode)"

$tsExe = "C:\Program Files\Tailscale\tailscale.exe"
L "Tailscale: exe present=$(Test-Path $tsExe)"

if (Test-Path $tsExe) {
  L "Tailscale: up"
  $out = & $tsExe up --auth-key="${ts_authkey}" --hostname=lab-windows --advertise-tags=tag:lab-windows --unattended 2>&1
  L "Tailscale up output: $out"
  $st = & $tsExe status 2>&1
  L "Tailscale status: $st"
}

"$(Get-Date -Format o)" | Set-Content C:\edr-bootstrap-complete
L "=== END ==="
