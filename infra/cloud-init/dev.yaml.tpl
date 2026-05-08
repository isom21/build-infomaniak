#cloud-config
hostname: dev
fqdn: dev.local
manage_etc_hosts: true
preserve_hostname: false

users:
  - default
  - name: dev
    gecos: edr-cloudlab dev user
    shell: /bin/bash
    groups: [users, sudo]
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - ${ssh_pubkey}

package_update: true
package_upgrade: false
packages:
  - curl
  - ca-certificates
  - gnupg
  - lsb-release
  - git
  - vim
  - htop
  - tmux
  - jq
  - unzip
  - build-essential
  - clang
  - lld
  - libbpf-dev
  - pkg-config
  - libssl-dev

write_files:
  - path: /etc/profile.d/edr-dev.sh
    permissions: '0644'
    content: |
      export EDITOR=vim

  - path: /usr/local/sbin/install-rust-as-dev.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      sudo -u dev -H bash -lc 'curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal'
      grep -q cargo/bin /home/dev/.bashrc || \
        echo "export PATH=\"\$HOME/.cargo/bin:\$PATH\"" >> /home/dev/.bashrc

  - path: /usr/local/sbin/install-claude-code.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
      DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
      npm install -g @anthropic-ai/claude-code

runcmd:
  # 1) Tailscale install + enroll (ssh-enabled, exit-node-advertised)
  - [bash, -c, "curl -fsSL https://tailscale.com/install.sh | sh"]
  - [bash, -c, "tailscale up --auth-key='${ts_authkey}' --hostname=dev --advertise-tags=tag:dev --ssh --advertise-exit-node --accept-routes"]

  # 2) Docker (official Docker repo)
  - [bash, -c, "install -m 0755 -d /etc/apt/keyrings"]
  - [bash, -c, "curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc && chmod a+r /etc/apt/keyrings/docker.asc"]
  - [bash, -c, "echo \"deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list"]
  - [bash, -c, "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"]
  - [bash, -c, "usermod -aG docker dev"]

  # 3) Node.js LTS + Claude Code CLI
  - [bash, /usr/local/sbin/install-claude-code.sh]

  # 4) Rust toolchain (as 'dev' user)
  - [bash, /usr/local/sbin/install-rust-as-dev.sh]

  # 5) Final marker — verification target for the orchestrator
  - [bash, -c, "tailscale ip -4 > /var/lib/edr-cloudlab-tailscale-ip"]
  - [bash, -c, "date -Iseconds > /var/lib/edr-cloudlab-bootstrap-complete"]
  - [bash, -c, "logger -t edr-cloudlab 'dev host bootstrap complete'"]

final_message: "edr-cloudlab dev host bootstrap finished after $UPTIME seconds"
