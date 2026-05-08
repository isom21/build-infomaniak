# 02 — Architecture

Three machines on Infomaniak Public Cloud (OpenStack), one Tailscale fabric, no public SSH anywhere.

## Why Infomaniak (single-provider)

- OpenStack-based, contributors come from CERN and Debian — robust open foundation
- Native Windows Server VMs available, no separate cloud needed for the kernel-debug lab
- Swiss data sovereignty, meaningful for security work
- One billing relationship, one Terraform provider (`terraform-provider-openstack`), one set of credentials
- Trade-off vs the prior Hetzner+Azure split: lose Hetzner's price floor on Linux compute, lose Azure's polish on Windows VM tooling — gain operational simplicity and provider portability (any OpenStack cloud can host this)

## Instance shapes

Flavor naming: `aN-ramM-diskD-perfP` where N=vCPU, M=GB RAM, D=GB disk, P=perf tier (perf1 = 500 IOPS / 200 MB/s, perf2 = 1000 IOPS / 400 MB/s).

| Role | Flavor | Why |
|---|---|---|
| **Dev host** (Claude Code + repo + compose stack) | `a8-ram32-disk80-perf2` (8 vCPU / 32 GB / 80 GB perf2) + 200 GB additional perf2 volume | The EDR stack (Postgres + Kafka + Flink + OpenSearch + FastAPI + Vite + Rust release builds) wants 32 GB RAM and fast NVMe. Perf2 tier matters for `cargo build` incremental cache and OpenSearch indexing. If builds feel tight, scale to `a16-ram32-disk80-perf2` (max standard flavor) — `openstack server resize` is a reboot. |
| **Linux lab** | `a2-ram4-disk80-perf1` (2 vCPU / 4 GB) in a separate OpenStack project | Real KVM kernel — needed for eBPF / kernel modules — and a separate project = separate API credentials = blast-radius boundary. Perf1 is plenty for a lab target. |
| **Windows lab** | `a4-ram16-disk80-perf2` (4 vCPU / 16 GB) | Windows Server needs more RAM than Linux just to idle. Perf2 for kernel-debugger VM responsiveness. Image: `Windows Server 2022 Datacenter` (Glance ID `28039fe3-0a79-4ed8-8d30-e3310e6aa7cc`). |

**Verified provisioning details (2026-05-08):**

- **Windows Server image**: `Windows Server 2022 Datacenter`, Glance ID `28039fe3-0a79-4ed8-8d30-e3310e6aa7cc`, public Infomaniak image. QCOW2/BARE, **UEFI firmware**, virtio + virtio-scsi drivers baked in, QEMU guest agent enabled, default admin user `administrator`, minimum 60 GB disk (our flavor provides 80 GB). `provider_image: win-2k22-datacenter-cloud-spla` confirms Windows licensing is bundled SPLA — no separate Microsoft license needed.
- **`nova shelve` stops compute billing** — confirmed; auto-stop strategy in [03-build-plan.md](03-build-plan.md) Phase 6 relies on this.
- **Nested virtualization is NOT available** — `kvm-ok` on a test instance reported "Your CPU does not support KVM extensions". The hypervisor does not expose VT-x/VMX or AMD-V to guests. Implications:
  - **Windows kernel debugging** uses **kdnet over Tailscale**: WinDbg runs on the dev host, connects to the Windows lab over TCP/IP kernel debugging. No Hyper-V guest needed inside the Windows VM.
  - **Snapshot/revert unit** for kernel-state experiments is the **Windows lab VM itself** (rebuild from Glance image via `make lab-reset` in 60-120s), not in-VM Hyper-V checkpoints.
  - **Linux EDR work** (eBPF, kernel modules, kernel selftests) is unaffected — runs on the bare kernel of the cloud VM.
  - This matches most public clouds; only AWS `*.metal` instances and Azure Dv3+ expose nested virt, neither of which Infomaniak offers.

## Network topology

Tailscale on all four nodes (3 VMs + laptop + phone). ACLs unchanged from the prior design — Tailscale is provider-agnostic:

- `tag:laptop, tag:mobile → tag:dev:22,*` allowed
- `tag:dev → tag:lab-*:*` allowed
- `tag:lab-* → tag:dev` **denied**
- `tag:lab-* → autogroup:internet` only via exit node `tag:dev` (or denied entirely if labs don't need internet)

OpenStack security groups deny everything except Tailscale UDP 41641 (per-network SGs `dev-sg`, `lab-linux-sg`, `lab-windows-sg`, applied automatically alongside the OpenStack `default` SG which permits intra-SG traffic and default egress). VS Code Remote-SSH connects via MagicDNS (`ssh dev`). Mobile uses Remote Control over the tailnet.

**Note on Infomaniak external networks:** Routers must use `ext-floating1` (`router:external: true`), **not** `ext-net1` (which is `router:external: false`, a shared direct-attach network — fine for VMs that take a public IP directly, but not as a router gateway).

### Network separation for blast radius

Single OpenStack project (`edr`) holds all three VMs. The blast-radius boundary is enforced at two layers, neither of which depends on project separation:

1. **Tailscale ACLs** deny `lab-* → dev` traffic (see ACL block above).
2. **No OpenStack credentials on the dev host** — `clouds.yaml` lives only on the laptop, so even a fully compromised dev host cannot create or destroy other VMs in the project.

Within the project, give each lab VM its own Neutron tenant network with no router to the dev network; they reach each other only via Tailscale.

**Optional hardening — split into two projects** (`edr-dev` and `edr-lab`) if you later want hard quota separation, separate billing line items, or isolated application credentials. Not necessary for a personal-scale setup.

### Access patterns mapping back to current workflow

- *VS Code today (extension on local)* → VS Code Remote-SSH into `dev`, extension/CLI run on the dev host, `~/.claude` lives there.
- *Phone today (`/remote-control`)* → identical command (`claude remote-control`) on the dev host. No port-forwarding needed thanks to outbound-only design.

## Identity & secrets

- **No long-lived SSH keys on disk.** Tailscale SSH with device-level auth; account login protected by TOTP 2FA (Tailscale, Infomaniak, Anthropic Console).
- **Claude Code authentication**: OAuth via `claude login` (default path for Claude.ai Pro/Max subscribers). Token persists in `~/.claude/` on the dev host; `claude logout` revokes that one host without touching other devices. **Alternative**: if you ever switch to metered API billing or want a fully headless service start with no interactive login, generate an API key in the Anthropic Console and store it via `systemd-creds` encrypted with the host TPM (`LoadCredentialEncrypted=` in the service unit). Either path keeps secrets out of `~/.bashrc` and the repo.
- **OpenStack application credentials** — laptop holds one `clouds.yaml` entry for the `edr` project. Dev host has no OpenStack credentials at all by default; that authority stays on the laptop. If automated lab teardown *from* the dev host is later wanted, mint a separate scoped application credential restricted to lab-VM-only operations and load it via `systemd-creds`.
- Repo secrets (DB passwords for the compose stack) via `sops` + `age`, key in `systemd-creds`.

## Snapshot / blast-radius recovery

- **Golden images via Packer + Terraform**, committed under `infra/`. One Packer template per lab OS produces an OpenStack image (Glance) in the `edr` project.
- **Pre-test snapshot**: `terraform taint` + `terraform apply` recreates a lab VM from the golden image in ~60-120 seconds (OpenStack creation is generally faster than Azure, slightly slower than Hetzner). Make `make lab-reset` a target Claude can call after a test trashes the VM.
- **Volume snapshots** on the dev host weekly; **Restic** to Infomaniak Swiss Backup (S3-compatible, same provider) or Backblaze B2 daily for `/home` and `/etc` (~$1/mo). Lab VMs are intentionally **not** backed up — they are cattle.
- Repo mirrored to a private Git remote; the dev host clones from there, never the other way.

## Cost controls

- **Dev host: always-on**. Infomaniak's a-series is hourly-billed but a continuously-running `a8-ram32` is predictable monthly spend.
- **Lab VMs: spin-up-on-demand** via `terraform apply -target=...`. OpenStack billing is per-second; `nova shelve` stops compute charges (verify!).
- **Auto-stop**: a systemd timer on the dev host watches `who`, Claude Code activity, and tmux sessions; if idle >2h, runs `terraform destroy` on lab VMs (not the dev host).
- **No spot/preemptible market** on Infomaniak — list prices apply. Already price-competitive vs major hyperscalers.
- **Cost estimation**: use Infomaniak's calculator at https://www.infomaniak.com/en/hosting/public-cloud/calculator with the flavors above. Rough expectation: dev host alone will dominate the bill; the lab VMs spun up on demand should add only single-digit CHF per month assuming idle-shutdown works.

## Considered alternatives (not chosen)

**Hetzner + Azure split** *(prior recommendation, superseded)* — Hetzner cheapest for Linux but Windows licensing is awkward, forcing an Azure split. Two billing relationships, two Terraform providers, more glue. Infomaniak's native Windows support eliminates the split.

**All-AWS, Coder.com on top** — managed dev-environment control plane with workspace templates, idle-shutdown built in. Replaces Ansible + Tailscale + systemd-timer glue with one product. Costs roughly 2-3× Infomaniak. Worth it to pay for polish over maintaining IaC.

**Single bare-metal Hetzner AX52 + Proxmox** — cheapest, strongest isolation, kernel-debug-friendly. Downside: now a part-time Proxmox sysadmin, host-level failure takes everything down. Recommend if that work is appealing.

**Other OpenStack clouds** (OVH, Cleura, etc.) — Terraform code from this project ports unchanged thanks to the standard `openstack` provider; only the auth endpoint and flavor names change. Real provider portability is a side benefit of the OpenStack choice.
