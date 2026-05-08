#cloud-config
hostname: lab-linux
fqdn: lab-linux.local
manage_etc_hosts: true
preserve_hostname: false

users:
  - default

package_update: true
package_upgrade: false
packages:
  - curl
  - ca-certificates
  - jq

runcmd:
  # Install Tailscale and join the tailnet with tag:lab-linux (ephemeral).
  - [bash, -c, "curl -fsSL https://tailscale.com/install.sh | sh"]
  - [bash, -c, "tailscale up --auth-key='${ts_authkey}' --hostname=lab-linux --advertise-tags=tag:lab-linux --ssh"]

  # Self-test: confirm what tailnet thinks we are. Output goes to console log.
  - [bash, -c, "tailscale status --self --json | jq '{Self:.Self|{HostName,TailscaleIPs,Tags,Online}}' | tee /var/lib/edr-cloudlab-tailscale-self"]

  # Marker
  - [bash, -c, "date -Iseconds > /var/lib/edr-cloudlab-bootstrap-complete"]
  - [bash, -c, "logger -t edr-cloudlab 'lab-linux bootstrap complete'"]

final_message: "edr-cloudlab lab-linux bootstrap finished after $UPTIME seconds"
