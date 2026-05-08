# 03 — Build plan

Six phases. Total effort estimate: ~1.5 working days for a competent operator.

**Deployment status (2026-05-08):** Phases 0, 1, 2, and 5-Linux are **applied**. Phase 5-Windows is scaffolded under [`infra/terraform/lab-windows/`](../infra/terraform/lab-windows/) but not applied. Phases 3, 4, 6 are user-side or hardening passes.

Live infrastructure summary is in [`../README.md`](../README.md) "Deployed state".

## Phase 0 — Prerequisites (laptop only, ~30 min)

1. **Create accounts**: Infomaniak account with Public Cloud enabled and one OpenStack project (`edr`); Tailscale (free tier is fine for ≤3 users); Backblaze B2 or Infomaniak Swiss Backup (for Restic); private Git remote (Gitea on dev host *later*, or GitHub for now).
2. **Generate one OpenStack application credential** for the `edr` project. Download `clouds.yaml` to the laptop only — never to the dev host (the dev host should not be able to destroy itself or its sibling labs).
3. **Plan Claude Code auth**: default is OAuth — run `claude login` on the dev host once it's up (Phase 2 step 10), browser flow opens on the laptop, paste the code back over SSH. Token persists in `~/.claude/`. Only generate an `ANTHROPIC_API_KEY` if you later switch to metered API billing or need fully headless service start; in that case use https://console.anthropic.com/ → Settings → API Keys, name it `edr-cloudlab-dev-host`, store in laptop password manager only.
4. **Enable TOTP 2FA on Tailscale, Infomaniak, and the Anthropic Console**. Use a password-manager-backed authenticator (Aegis, 1Password, Authy) so codes are recoverable. Do this before adding any nodes.
5. **Provisioning facts already verified** (see [02-architecture.md](02-architecture.md) "Verified provisioning details"):
   - Windows image `28039fe3-0a79-4ed8-8d30-e3310e6aa7cc`, SPLA-licensed, UEFI, virtio drivers
   - `nova shelve` stops compute billing
   - **Nested virtualization is not available** → Windows kernel debugging uses **kdnet over Tailscale** (WinDbg on dev host, kernel debug TCP to Windows lab); the lab VM itself is the snap/revert unit. Plan the Windows Packer template (Phase 5 step 19) and Tailscale ACL (Phase 1) accordingly.
6. **`infra/` directory exists** in this repo with empty subdirs: `ansible/`, `terraform/dev/`, `terraform/lab-linux/`, `terraform/lab-windows/`, `packer/`. Future home of the whole stack-as-code.

## Phase 1 — Tailscale fabric (~45 min)

Detailed walkthrough lives in **[05-tailscale-setup.md](05-tailscale-setup.md)**. The summary:

5. Create tailnet, enable TOTP 2FA on the Tailscale account ([05 step 1.1](05-tailscale-setup.md)).
6. Edit ACL policy file in the admin console (tags + acls + ssh + autoApprovers); copy the policy block from [05 step 1.2](05-tailscale-setup.md) verbatim.
7. Generate three auth keys (dev: non-reusable/non-ephemeral; lab-linux + lab-windows: reusable/ephemeral; all pre-approved with their tag). Save to laptop password manager. ([05 step 1.3](05-tailscale-setup.md))
8. Enroll laptop and phone with `tag:laptop` / `tag:mobile`. ([05 steps 1.4-1.5](05-tailscale-setup.md))
9. Confirm tailnet membership and tags from the admin console ([05 step 1.6](05-tailscale-setup.md)). Lab-isolation ACLs become fully testable in Phase 5 once lab VMs join.

## Phase 2 — Dev host (~2 hr)

8. **Provision via Terraform**: `infra/terraform/dev/main.tf` uses the `terraform-provider-openstack` against the `edr` project, declares one `a8-ram32-disk80-perf2` instance on a `dev` Neutron tenant network, attaches a 200 GB perf2 Cinder volume for `/home/dev`, Ubuntu 24.04 image, cloud-init that installs Tailscale with the dev auth key and configures the security group to deny all inbound except `41641/udp`.
9. **Ansible playbook `infra/ansible/dev.yml`** layers on:
   - Docker + compose plugin
   - Rust toolchain via rustup (pinned to the EDR project's `rust-toolchain.toml`)
   - Build deps for the kernel-side C bits (`build-essential`, `clang`, `lld`, `libbpf-dev`)
   - Node.js LTS for the React UI
   - Claude Code CLI (`npm i -g @anthropic-ai/claude-code` or the official installer per docs)
   - A non-root `dev` user; SSH only via Tailscale SSH (no `authorized_keys` on the public interface)
   - `claude-remote-control.service` systemd unit (uses OAuth token from `~/.claude/` after a one-time `claude login`; if you chose API-key auth in Phase 0 step 3 instead, the unit loads it via `LoadCredentialEncrypted=` from `systemd-creds`)
10. **Smoke test on the host**: `claude --version`, `docker compose version`, `cargo --version`, `tailscale status`. Then run `claude login` over SSH to complete OAuth (paste the URL into your laptop browser, paste the resulting code back).

## Phase 3 — Repo + stack on the dev host (~1 hr)

11. **Mirror the repo**: push `/mnt/d/priv/code/edr` to private Git remote. On the dev host, clone to `/home/dev/edr`.
12. **Bring up the backend**: `docker compose up -d` for Postgres/OpenSearch/Kafka/Flink/FastAPI. Watch memory — if OpenSearch+Kafka heaps push past 24 GB resident, scale to CCX43 now rather than later.
13. **Build once end-to-end**: `cargo build --release` for the agent, `npm run build` for the UI. Record wall-clock times as performance baseline.

## Phase 4 — Connect VS Code and mobile (~30 min)

14. **VS Code Remote-SSH**: add an SSH host `dev` (Tailscale MagicDNS name). Open `/home/dev/edr` remotely. Install the Claude Code VS Code extension *into the remote* (it'll prompt). Confirm the extension drives the CLI on the dev host, not the laptop.
15. **Mobile / Remote Control**: on the dev host, `systemctl --user start claude-remote-control` (or `claude remote-control` in tmux). Pair from claude.ai/code on phone — **test on cellular, not home wifi**, to prove the tailnet+outbound-HTTPS path is the only thing in play.
16. **Decommission local Claude usage**: stop launching `claude` from WSL2. Laptop is now a thin client.

## Phase 5 — Lab VMs (~3 hr — the longest phase)

All lab IaC targets the same `edr` OpenStack project as the dev host but on dedicated Neutron tenant networks (`lab-linux`, `lab-windows`) with no inter-network routing — isolation is enforced by the Tailscale ACL, not by project boundaries.

17. **Linux lab — Packer template** in `infra/packer/lab-linux.pkr.hcl`: `openstack` builder, Ubuntu 24.04 base, kernel headers matching the running kernel, test harness binary, Tailscale with `tag:lab-linux` ephemeral key. Output: a Glance image in the `edr` project.
18. **Linux lab — Terraform** in `infra/terraform/lab-linux/`: one `a2-ram4-disk80-perf1` instance from the Glance image, on its own `lab-linux` Neutron tenant network with no router to `dev`, Tailscale-only.
19. **Windows lab — Packer**: `openstack` builder against image `Windows Server 2022 Datacenter` (Glance ID `28039fe3-0a79-4ed8-8d30-e3310e6aa7cc`). Connect via WinRM as `administrator` (cloudbase-init delivers the password on first boot). Boot mode UEFI. Pre-install:
    - WinDbg + Debugging Tools for Windows
    - Test-signing enabled (`bcdedit /set testsigning on`)
    - **kdnet configured** (`bcdedit /dbgsettings net hostip:<dev-host-tailnet-IP> port:50000 key:<generate>`) — kernel debugger on the dev host attaches over the tailnet
    - Driver-loading harness
    - Tailscale Windows client with `tag:lab-windows` ephemeral key
    Output: Glance image. Tailscale ACL must allow `tag:dev → tag:lab-windows:50000/udp` for kdnet (kdnet uses UDP).
20. **Windows lab — Terraform** in `infra/terraform/lab-windows/`: one `a4-ram16-disk80-perf2` instance from the Glance image, separate Neutron tenant network, security group denies all inbound except Tailscale.
21. **Make targets** in repo root:
    - `make lab-up` → `terraform apply` both labs
    - `make lab-reset` → `terraform taint` both VMs + apply (golden-image rebuild in ~60-120s on OpenStack)
    - `make lab-down` → `terraform destroy` both labs
22. **Run one full test cycle**: build agent on dev host → `scp` to Linux lab → trigger detection → `make lab-reset`. Time it. Tune until reset < 2 min.

## Phase 6 — Hardening & cost controls (~1 hr)

23. **Idle auto-stop**: systemd timer on dev host watches `who`, tmux sessions, and recent Claude activity; if idle > 2h, runs `make lab-down`. Dev host stays up (interrupting `cargo build` is misery).
24. **OpenStack scheduled `nova shelve`** as belt-and-suspenders for the Windows lab at 02:00 UTC.
25. **Restic backups**: daily snapshot of `/home/dev` and `/etc` to Infomaniak Swiss Backup or Backblaze B2. ~$1/mo.
26. **OpenStack volume snapshots** weekly on the dev host's data volume.
27. **Break-glass**: document Infomaniak Manager console access (Horizon dashboard) as the "Tailscale is down" recovery path. Test it once.
