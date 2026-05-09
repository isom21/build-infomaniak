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
2. [docs/02-architecture.md](docs/02-architecture.md) — recommended architecture: Infomaniak + Tailscale, instance shapes, network topology, secrets handling, snapshot/restore strategy, costs
3. [docs/03-build-plan.md](docs/03-build-plan.md) — six-phase step-by-step build plan
4. [docs/04-migration-paths.md](docs/04-migration-paths.md) — cutover from local WSL2, rollback, provider portability, scaling to team use
5. [docs/05-tailscale-setup.md](docs/05-tailscale-setup.md) — detailed step-by-step for the Tailscale fabric (expands build plan Phase 1)

## Layout

```
edr-cloudlab/
├── README.md
├── docs/                 # research, architecture, plan, migration
└── infra/
    ├── Makefile          # convenience targets (dev-apply, lab-up, ts-status, …)
    ├── tf-with-env       # wrapper that loads secrets/clouds.yaml before terraform
    ├── ansible/          # dev host configuration management (idempotent re-runs)
    ├── cloud-init/       # cloud-init / cloudbase-init templates for VM bootstrap
    ├── packer/           # golden images for lab VMs (not yet used)
    └── terraform/
        ├── network/      # 3 Neutron networks + routers + Tailscale-only SGs
        ├── dev/          # Infomaniak a8-ram32-disk80-perf1 dev host
        ├── lab-linux/    # Infomaniak a2-ram4-disk80-perf1 Linux test VM
        └── lab-windows/  # Infomaniak a4-ram16-disk80-perf1 Windows test VM
```

## Status

All three VMs are deployed via Terraform and joined to the tailnet. End-to-end
rebuild from `infra/` works: `make dev-apply`, `make lab-linux-apply`,
`make lab-windows-apply`. `lab-windows` provisions via a deferred scheduled
task (3-minute delay after first boot) so cloudbase-init's SYSTEM-context can
install Tailscale's MSI cleanly — see [infra/cloud-init/lab-windows.yaml.tpl](infra/cloud-init/lab-windows.yaml.tpl).

### Deployed state (region `dc4-a`)

| Role | Tailnet IP | OpenStack name | Fixed IP | Floating IP | Flavor |
|---|---|---|---|---|---|
| Dev host | `100.111.232.7` | `dev` | `10.10.10.125` | `83.228.249.160` | `a8-ram32-disk80-perf1` |
| Linux lab | `100.99.225.128` | `lab-linux` | `10.10.20.15` | `83.228.248.104` | `a2-ram4-disk80-perf1` |
| Windows lab | `100.79.153.93` | `lab-windows` | `10.10.30.244` | `83.228.249.250` | `a4-ram16-disk80-perf1` |

All security groups allow only Tailscale UDP/41641 ingress. Public SSH/RDP/HTTP are closed.

## Accessing the machines

Tailscale MagicDNS resolves the short hostnames. All commands assume the
calling device is on the tailnet (laptop tagged `tag:laptop`, phone
tagged `tag:mobile`).

### From your laptop (`tag:laptop`)

| Target | Method | Command |
|---|---|---|
| `dev` | **Tailscale SSH** (no key) | `ssh dev` |
| `dev` | VS Code Remote-SSH | Add SSH host `dev`, open folder remotely; the Claude Code extension installs into the remote |
| `lab-linux` | **Tailscale SSH** | `tailscale ssh ubuntu@lab-linux` |
| `lab-linux` | OpenSSH (fallback) | `ssh -i secrets/edr-dev.key ubuntu@lab-linux` |
| `lab-windows` | **RDP** | `mstsc /v:lab-windows` (Win) · `xfreerdp /v:lab-windows /u:Administrator /p:'<pwd>'` (Linux) |
| `lab-windows` | OpenSSH (after one-time pubkey injection via RDP) | `ssh Administrator@lab-windows` |

### From `dev` (`tag:dev`)

```bash
tailscale status                                # show all peers, ACL state
tailscale ping lab-linux                        # round-trip + path
tailscale ssh ubuntu@lab-linux                  # zero-key SSH
ssh -i ~/.ssh/edr-dev.key ubuntu@lab-linux      # OpenSSH if you've copied the key
```

For Windows kernel debugging, use **kdnet over the tailnet** (WinDbg on `dev`,
target `lab-windows` UDP/50000). The kdnet step is a commented placeholder
in [infra/cloud-init/lab-windows-inner.ps1.tpl](infra/cloud-init/lab-windows-inner.ps1.tpl);
populate the dev tailnet IP and uncomment to enable on next `make lab-windows-apply`.

### From your phone (`tag:mobile`)

Phone is allowed only to `tag:dev` (intentional — labs aren't exposed to a
device with higher loss-of-control risk).

- **Claude Code Remote Control** (does NOT need Tailscale — outbound HTTPS only):
  on `dev`, run `claude remote-control` in tmux. Open the Claude app or
  https://claude.ai/code on your phone, pair the session.
- **Direct SSH/diagnostic** (does need Tailscale): install the Tailscale app
  from the App Store / Play Store, sign in, tag the device `tag:mobile` in the
  admin console.

### Retrieving the Windows Administrator password

Each `make lab-windows-apply` produces a fresh random password. cloudbase-init
encrypts it with the OpenStack RSA keypair (`edr-dev-rsa`) and posts it to
metadata; decrypt it with `secrets/edr-dev-rsa.key`:

```bash
# 1) Set OpenStack creds (nova CLI doesn't honor --os-cloud; parse from clouds.yaml)
python3 -c "
import yaml
c = yaml.safe_load(open('/mnt/d/priv/code/PCU-9UAH2PR-clouds.yaml'))
a = c['clouds']['PCP-9UAH2PR-dc4-a']['auth']
print(f'''export OS_AUTH_URL={a[\"auth_url\"]}
export OS_USERNAME={a[\"username\"]}
export OS_PASSWORD={a[\"password\"]!r}
export OS_PROJECT_NAME={a[\"project_name\"]}
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_DOMAIN_NAME=default
export OS_IDENTITY_API_VERSION=3''')
" > /tmp/os-env.sh && . /tmp/os-env.sh

# 2) Decrypt
nova get-password lab-windows secrets/edr-dev-rsa.key | tail -1
```

The private key is in PEM (`BEGIN RSA PRIVATE KEY`) format — both `nova
get-password` (which shells out to `openssl pkeyutl`) and `openssl pkeyutl`
directly can read it. ssh-keygen originally writes ed25519/RSA keys in
OpenSSH format; if you regenerate the keypair, convert to PEM with
`ssh-keygen -p -m PEM -f secrets/edr-dev-rsa.key -N "" -P ""` (or via
`cryptography.serialization.PrivateFormat.TraditionalOpenSSL` from Python).

### Connectivity / ACL test

```bash
# From laptop — should all succeed:
tailscale ping dev
tailscale ping lab-linux
tailscale ping lab-windows

# From lab-linux (after `tailscale ssh ubuntu@lab-linux`) — should FAIL:
tailscale ping dev          # default-deny: lab-* cannot originate to anywhere
tailscale ping lab-windows  # same
```

### ACL summary (live policy)

| Source | → Destination | Allowed |
|---|---|---|
| `tag:laptop` | `tag:dev:*` | ✅ |
| `tag:laptop` | `tag:lab-linux:*`, `tag:lab-windows:*` | ✅ |
| `tag:mobile` | `tag:dev:*` | ✅ |
| `tag:mobile` | `tag:lab-*` | ❌ |
| `tag:dev` | `tag:lab-*:*` | ✅ |
| `tag:lab-*` | anything | ❌ (default-deny) |

The full HuJSON policy lives in the Tailscale admin console — see [docs/05-tailscale-setup.md](docs/05-tailscale-setup.md) section 1.2 for the canonical version.
