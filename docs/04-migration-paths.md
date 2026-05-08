# 04 — Migration paths

## Path A — Cutover from current local WSL2 (the main one)

**Goal: 1-2 days, no lost work.**

1. **Day before cutover**: complete Phases 0-4 from [03-build-plan.md](03-build-plan.md). Dev host is alive but local WSL2 still in use.
2. **Cutover day morning**: commit and push every uncommitted change in `/mnt/d/priv/code/edr` on WSL2. `git status` clean.
3. **Pull on dev host**: `git pull`. Re-run `cargo build` to confirm parity.
4. **Move ephemeral state**:
   - Postgres data: `pg_dump` on WSL2 → restore on dev host (or skip if reseeding is acceptable)
   - Any `.env.local` files: copy via `scp` over Tailscale, then move secrets into `systemd-creds`
   - Notes/scratch dirs not in git: rsync over Tailscale
5. **Switch VS Code window** from WSL2 to Remote-SSH `dev`. Verify the extension is functional.
6. **Pair phone Remote Control** to dev host.
7. **Soak for 3-5 days** with WSL2 still installed but unused. If anything's broken, fall back instantly.
8. **After soak**: stop the WSL2 Docker stack, free the disk, but don't uninstall WSL2 itself for another month.

## Path B — Rollback if cloud setup misbehaves

Designed in from day one because Path A overlaps with WSL2:

- Dev host is *additive*, not destructive. WSL2 stays bootable for ~30 days post-cutover.
- Repo is the source of truth — any state on the dev host that isn't in git is by definition rebuildable.
- To roll back: `git pull` on WSL2, restart local docker compose, point VS Code back at WSL2. ~10 minutes.
- Cost of rolling back: the month's Infomaniak spend, nothing else.

## Path C — Provider portability (future-proofing)

Choosing OpenStack as the foundation pays off here: the `terraform-provider-openstack` and Packer's `openstack` builder are vendor-neutral. Switching from Infomaniak to another OpenStack cloud usually means changing only the auth endpoint, region, and flavor names — not rewriting any resource definitions.

- **Infomaniak → another OpenStack cloud** (OVH, Cleura, CloudFerro, on-prem): swap `clouds.yaml`, adjust flavor names to the destination's catalog, re-run Packer to bake images on the new cloud. Terraform module structure unchanged.
- **Infomaniak → AWS** (if a feature like spot instances becomes worth it): rewrite `terraform/*/main.tf` for `aws_instance`, change Packer's `source` block from `openstack` to `amazon-ebs`. Ansible playbooks and the test harness unchanged.
- **Self-hosted bare-metal** (Alternative B in [02-architecture.md](02-architecture.md)): Proxmox or even DevStack as a personal OpenStack — the latter keeps Terraform/Packer code byte-identical. Ansible roles port directly.

The Tailscale fabric is provider-agnostic, so the access pattern (VS Code Remote-SSH, mobile Remote Control) survives any migration unchanged.

## Path D — Escalating to enterprise / team use

If a teammate joins later:

- Tailscale ACLs already have user/tag separation — add their identity, give `tag:laptop` membership.
- Anthropic workspace API key → switch to per-user keys, drop the shared one from `systemd-creds`.
- Add a real CI runner (GitHub Actions self-hosted on a separate Hetzner box, *not* the dev host) so builds aren't single-tenant.
