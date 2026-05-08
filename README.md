# edr-cloudlab

Cloud-hosted development environment and isolated test lab for the EDR PoC at
[../edr/](../edr/). Moves Claude Code off the local WSL2 box onto a dedicated
cloud dev host, plus disposable Linux + Windows lab VMs for agent testing.

**Cloud provider:** Infomaniak Public Cloud (OpenStack-based, single-provider
for both Linux and Windows VMs).

## Goals

- Run Claude Code on a remote dev host instead of the local machine
- Drive it from VS Code (Remote-SSH) and from a phone (Claude Code Remote Control), exactly like today
- Keep an isolated Linux + Windows test lab the dev host can deploy to and reset in minutes
- No public ingress anywhere — Tailscale-only access, outbound HTTPS only for Anthropic
- Recoverable in minutes when a kernel-driver test trashes a lab VM

## Documents

1. [docs/01-research.md](docs/01-research.md) — synthesis of Anthropic's official docs on remote/cloud Claude Code, Remote Control, VS Code Remote-SSH, Dev Containers
2. [docs/02-architecture.md](docs/02-architecture.md) — recommended architecture: Hetzner + Azure + Tailscale, instance shapes, network topology, secrets handling, snapshot/restore strategy, costs
3. [docs/03-build-plan.md](docs/03-build-plan.md) — six-phase step-by-step build plan
4. [docs/04-migration-paths.md](docs/04-migration-paths.md) — cutover from local WSL2, rollback, provider portability, scaling to team use
5. [docs/05-tailscale-setup.md](docs/05-tailscale-setup.md) — detailed step-by-step for the Tailscale fabric (expands build plan Phase 1)

## Layout

```
edr-cloudlab/
├── README.md
├── docs/                 # research, architecture, plan, migration
└── infra/
    ├── ansible/          # dev host configuration management
    ├── packer/           # golden images for lab VMs
    └── terraform/
        ├── dev/          # Hetzner CCX33 dev host
        ├── lab-linux/    # Hetzner CX22 Linux test VM
        └── lab-windows/  # Azure D4s_v5 Windows test VM
```

## Status

Phases 0, 1, 2 (dev host), and 5 (Linux lab) are **deployed**. Phase 5 Windows lab is **scaffolded but not applied** — see `infra/terraform/lab-windows/` and the open items at the top of that `main.tf`.

### Deployed state (region `dc4-a`)

| Role | Tailnet IP | OpenStack name | Fixed IP | Floating IP | Flavor |
|---|---|---|---|---|---|
| Dev host | `100.84.73.94` | `dev` | `10.10.10.125` | `83.228.249.160` | `a8-ram32-disk80-perf1` |
| Linux lab | `100.72.229.127` | `lab-linux` | `10.10.20.15` | `83.228.248.104` | `a2-ram4-disk80-perf1` |
| Windows lab | — | (not provisioned) | — | — | `a4-ram16-disk80-perf1` (planned) |

Both VMs are joined to the tailnet with the right tags. Tailscale ACL enforces:
`tag:laptop, tag:mobile → tag:dev:*` allowed, `tag:dev → tag:lab-*:*` allowed,
`tag:lab-* → anything` denied (default-deny).

### Next manual steps

1. **Enroll your laptop and phone** on the tailnet — see [docs/05-tailscale-setup.md](docs/05-tailscale-setup.md) sections 1.4-1.5. Tag them `tag:laptop` and `tag:mobile` in the Tailscale admin console after enrolment.
2. **From the laptop**, `ssh dev` (Tailscale SSH, no key needed). Then run `claude login` once on the dev host to set up OAuth.
3. **VS Code Remote-SSH** → `dev` host. The Claude Code extension installs into the remote.
4. **Phone Remote Control**: on the dev host, run `claude remote-control` (or wire a systemd unit). Pair from claude.ai/code on the phone.
5. **Cleanup later**: when you're done with the `test nested virt` VM, delete it and the `lab-ssh-icmp` security group.
