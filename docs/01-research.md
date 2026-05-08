# 01 — Research: official Anthropic guidance on remote Claude Code

Synthesis of relevant findings from Anthropic's official documentation
(code.claude.com/docs) for moving a Claude Code workflow onto a cloud VM
while preserving VS Code and mobile access.

## Key insight

The feature locally referred to as `/remote-control` is officially **Remote
Control** (research preview). It works by having the Claude Code process
*poll Anthropic over outbound HTTPS* — no inbound ports, no tunnels, no public
IP needed. That single fact reshapes the design: **wherever Claude Code runs,
it can be driven from a phone with zero ingress exposure.** A cloud host can
sit on a private tailnet behind a default-deny firewall and mobile still works.

## The three official remote patterns

### 1. Claude Code on the Web

Fully managed sessions at claude.ai/code on Anthropic infrastructure. Closest
to "no-ops cloud", but does not allow attaching custom Windows/Linux lab VMs
to it. Ruled out for EDR work that needs kernel-debug-realistic lab targets.

Source: https://code.claude.com/docs/en/claude-code-on-the-web.md

### 2. Dev Containers + VS Code Remote-SSH

The documented way to run the VS Code extension against a remote host. The
reference config at `github.com/anthropics/claude-code/.devcontainer` includes
a network-egress firewall script. Extension and CLI both run inside the
container on the remote host and share `~/.claude` configuration.

Source: https://code.claude.com/docs/en/devcontainer.md

### 3. Claude Code Desktop SSH

The Desktop app has a first-class "SSH connection" mode that auto-installs
Claude Code on the remote (Linux/macOS only) and provides the full UI against
it. Simpler than the dev container pattern; less isolation.

Source: https://code.claude.com/docs/en/vs-code.md

## Remote Control specifics

- Officially in research preview across all plans
- Off by default on Team/Enterprise until an admin enables it
- Mechanism: local Claude Code session registers with the Anthropic API and
  polls for work from claude.ai/code or the Claude mobile app
- All traffic encrypted over TLS through Anthropic's servers
- **Outbound HTTPS only** — no port forwarding or tunnel needed; works
  behind NAT or restrictive firewalls

Source: https://code.claude.com/docs/en/remote-control.md

## Sandboxing / EDR-relevant notes

- Dev containers can restrict network egress to only required domains
  (firewall script in the reference config)
- For untrusted code or testing, docs recommend mounting volumes carefully
  (avoid `~/.ssh` or credential files) and using network restrictions
- **Not documented**: spinning up disposable Windows/Linux test VMs from a
  Claude-driven host, nested-virt configs. The user must architect this
  independently (Terraform, Packer, Vagrant, etc.) and ensure outbound
  HTTPS from the host is available for Remote Control and API calls.

Source: https://code.claude.com/docs/en/sandboxing.md

## Implications for the EDR project

1. The cloud host needs only outbound HTTPS to function. No public SSH, no
   tunneling product needed for mobile access. This is the strongest
   security property of the design.
2. VS Code Remote-SSH is the cleanest path for laptop access; Dev Containers
   add isolation if the dev host itself is multi-tenant (it isn't, here).
3. The lab VMs are entirely outside Anthropic's documented patterns —
   custom Terraform + Packer territory.

## Source index

- Claude Code on the Web — https://code.claude.com/docs/en/claude-code-on-the-web.md
- Remote Control — https://code.claude.com/docs/en/remote-control.md
- VS Code extension — https://code.claude.com/docs/en/vs-code.md
- Dev Containers — https://code.claude.com/docs/en/devcontainer.md
- Sandboxing — https://code.claude.com/docs/en/sandboxing.md
- Documentation index — https://code.claude.com/docs/llms.txt
