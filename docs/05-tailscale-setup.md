# 05 — Tailscale setup (Phase 1, expanded)

Concrete walkthrough for the Tailscale fabric described in [02-architecture.md](02-architecture.md). This expands [03-build-plan.md](03-build-plan.md) Phase 1.

## What we're building

```
                       ┌─────────────┐
                       │   Anthropic │   (outbound HTTPS only;
                       │     API     │    Remote Control polls)
                       └──────┬──────┘
                              │
   ┌──────────┐               │
   │  Phone   │ ──── TLS ─────┘
   │ (mobile) │
   └────┬─────┘
        │ tailnet
   ┌────┴─────┐    tailnet     ┌──────────┐    tailnet    ┌───────────────┐
   │  Laptop  │ ─────────────► │ Dev host │ ─────────────► │ Linux lab VM  │
   │ (laptop) │                │  (dev)   │                │ (lab-linux)   │
   └──────────┘                └────┬─────┘                └───────────────┘
                                    │ tailnet
                                    └─────────────────────► ┌─────────────────┐
                                                            │ Windows lab VM  │
                                                            │ (lab-windows)   │
                                                            └─────────────────┘

   Allowed:  laptop/mobile → dev    dev → lab-*
   Denied:   lab-*  → dev           lab-* → laptop/mobile
   Denied:   lab-*  → internet (except via dev as exit node)
```

## Order of operations

You build the **policy first** in the admin console (steps 1.1-1.3), enroll your **personal devices** (steps 1.4-1.5), then enroll **VMs as they come up** in Phases 2 and 5 of the main build plan via cloud-init.

---

## 1.1 Create account & tailnet (5 min)

1. Go to https://login.tailscale.com/start.
2. Sign in with the identity provider you want as the long-term tailnet owner — Google, GitHub, Microsoft, Apple, or email. Pick one you control durably; tailnet ownership is hard to migrate.
3. Pick **Personal** plan (free). Up to 100 devices, 3 users, ACLs, Tailscale SSH, MagicDNS, exit nodes — everything in this design works on free.
4. **Enable TOTP 2FA** at https://login.tailscale.com/admin/settings/personal → "Account security" — protects the entire tailnet from a stolen identity-provider session.
5. Note your **tailnet name** at https://login.tailscale.com/admin/settings/general (e.g. `tailnet-foo123.ts.net`). Hosts on the tailnet will be addressable as `<host>.<tailnet>.ts.net`.

## 1.2 Define tags & ACLs (15 min)

Tailscale identifies machines by **tags**, not user accounts. Tags are claimed at enroll time (auth key) and enforced by the policy file.

1. Go to **Access Controls** → https://login.tailscale.com/admin/acls/file.
2. Replace the entire policy with the file below. It's HuJSON (JSON with comments and trailing commas allowed).

   ```hujson
   {
     // Owners can assign these tags to devices via auth keys.
     // autogroup:admin = users with "Owner" or "Admin" role on the tailnet.
     "tagOwners": {
       "tag:dev":         ["autogroup:admin"],
       "tag:lab-linux":   ["autogroup:admin"],
       "tag:lab-windows": ["autogroup:admin"],
       "tag:laptop":      ["autogroup:admin"],
       "tag:mobile":      ["autogroup:admin"],
     },

     "acls": [
       // Personal devices can reach the dev host on any port.
       {
         "action": "accept",
         "src":    ["tag:laptop", "tag:mobile"],
         "dst":    ["tag:dev:*"],
       },

       // Dev host can reach lab VMs on any port (SSH, kdnet, RDP, etc).
       // kdnet uses UDP/50000 by default — covered by "*".
       {
         "action": "accept",
         "src":    ["tag:dev"],
         "dst":    ["tag:lab-linux:*", "tag:lab-windows:*"],
       },

       // No rule lets lab-* originate connections to anything else,
       // so labs cannot reach dev, laptop, mobile, or each other.
       // (Tailscale ACLs default-deny.)
     ],

     "ssh": [
       // Tailscale SSH from laptop to dev host as user 'dev' or 'root'.
       // Note: 'check' (interactive re-auth) only supports user identities
       // in src, not tags. Use 'accept' for tag-based src — tailnet
       // membership + the ACL is the auth boundary.
       {
         "action": "accept",
         "src":    ["tag:laptop"],
         "dst":    ["tag:dev"],
         "users":  ["root", "dev"],
       },
     ],

     // Auto-approve the dev host advertising itself as an exit node,
     // so we can later route lab VM internet egress through it.
     "autoApprovers": {
       "exitNode": ["tag:dev"],
     },
   }
   ```

3. Click **Save**. The console validates syntax and previews policy changes; if anything's wrong it tells you which line.

## 1.3 Generate auth keys (5 min)

Go to **Settings → Keys** → https://login.tailscale.com/admin/settings/keys. Click **Generate auth key** for each role below.

| Purpose | Reusable | Ephemeral | Pre-approved | Tags |
|---|---|---|---|---|
| **Dev host** | No | No | Yes | `tag:dev` |
| **Linux lab** | Yes (rebuild from image many times) | **Yes** (auto-deregister on shutdown) | Yes | `tag:lab-linux` |
| **Windows lab** | Yes | **Yes** | Yes | `tag:lab-windows` |

- "Reusable" lets one key enroll multiple devices — needed for the labs because `make lab-reset` rebuilds them repeatedly.
- "Ephemeral" makes Tailscale forget the device when it goes offline, so destroyed lab VMs don't accumulate as stale nodes.
- "Pre-approved" skips the manual admin approval step (we want lab VMs to come up without you tapping a button).

**Save each key to your laptop password manager.** They're shown once. They're the credentials cloud-init will use.

For laptop and phone you don't generate auth keys — those enroll interactively.

## 1.4 Enroll your laptop (5 min)

### Linux (e.g. WSL2 Ubuntu)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-tags=tag:laptop
```

The CLI prints a URL — open it in any browser, sign in to Tailscale (same identity as 1.1), and click **Connect**. The first time you'll need to **manually approve the `tag:laptop` claim** in the admin console at https://login.tailscale.com/admin/machines (laptops can't claim tags via auth key without an admin approving it the first time).

### Windows (native, not WSL)

1. Download the MSI from https://tailscale.com/download/windows.
2. Install, sign in.
3. After it shows up at https://login.tailscale.com/admin/machines, click the row → **Edit ACL tags** → add `tag:laptop`.

### macOS

```bash
brew install --cask tailscale
```

Then sign in via the menu bar icon. Add `tag:laptop` from the admin console.

### Verify

```bash
tailscale status        # should show your laptop online with tag:laptop
tailscale ip -4         # your tailnet IPv4 (100.x.y.z)
```

## 1.5 Enroll your phone (3 min)

1. Install **Tailscale** from the App Store (iOS) or Play Store (Android).
2. Sign in with the same identity.
3. Go to https://login.tailscale.com/admin/machines, find your phone, **Edit ACL tags** → `tag:mobile`.
4. Toggle Tailscale **on** in the app. The phone gets a 100.x.y.z tailnet address.

The phone now has tailnet connectivity, but **mobile Remote Control does not require it** — the phone reaches the dev host's Claude session via Anthropic's servers, outbound HTTPS only. Tailnet membership is just so you can also SSH from your phone in a pinch (e.g. via Termius).

## 1.6 Verify ACLs (5 min, do this before deploying real VMs)

You can test ACL behavior without VMs by enrolling a throwaway second machine (or another laptop). For now, the meaningful check is just:

- https://login.tailscale.com/admin/acls/file shows your policy without errors
- https://login.tailscale.com/admin/machines lists your laptop and phone with the right tags
- `tailscale ping <phone-tailnet-ip>` from laptop works

The lab-isolation rules become testable once VMs are enrolled in Phase 5 of the main build plan. Plan to verify then:

- From dev host: `tailscale ping <lab-linux-tailnet-name>` → should succeed
- From lab Linux VM: `tailscale ping <dev-tailnet-name>` → should **fail** (`Could not reach destination`)
- From lab Linux VM: `tailscale ping <lab-windows-tailnet-name>` → should **fail**

If those don't behave as expected, the ACL is misconfigured — go back to 1.2.

---

## Enrolling VMs (later, during Phases 2 and 5)

This is the cloud-init pattern you'll bake into Terraform/Packer. The auth keys from 1.3 go into Terraform variables (`TF_VAR_tailscale_auth_key_dev` etc.), never into committed files.

### Linux (Ubuntu 24.04 dev host or lab)

cloud-init `user-data`:

```yaml
#cloud-config
package_update: true
runcmd:
  - curl -fsSL https://tailscale.com/install.sh | sh
  - tailscale up --auth-key=${TS_AUTHKEY} --ssh --hostname=${HOSTNAME} --advertise-tags=${TAG}
  # Dev host only: also advertise as exit node for the lab subnet
  # - tailscale up --auth-key=${TS_AUTHKEY} --ssh --hostname=dev --advertise-tags=tag:dev --advertise-exit-node
```

`--ssh` enables Tailscale SSH (replaces OpenSSH key management — see 1.2 ACL `ssh` block). With `--ssh`, you do not need to install your laptop's public key on the dev host; identity is enforced by the tailnet.

### Windows (lab Windows VM)

In the Packer template's PowerShell provisioner:

```powershell
# Download and silently install
Invoke-WebRequest -Uri "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe" -OutFile "$env:TEMP\tailscale.exe"
Start-Process -Wait -FilePath "$env:TEMP\tailscale.exe" -ArgumentList "/quiet"

# At first boot of the spawned VM (not bake-time), connect via cloudbase-init userdata:
& "C:\Program Files\Tailscale\tailscale.exe" up `
    --auth-key=$env:TS_AUTHKEY `
    --hostname=lab-windows `
    --advertise-tags=tag:lab-windows
```

Tailscale SSH on Windows is limited; just use OpenSSH or RDP over the tailnet for lab access from the dev host.

---

## Reference: useful Tailscale commands

```bash
tailscale status                     # who's on the tailnet
tailscale ip -4                      # this node's tailnet IPv4
tailscale ping <node>                # latency + path (DERP relay vs direct)
tailscale ssh <user>@<node>          # tailnet SSH (no keys needed)
tailscale netcheck                   # NAT/UDP traversal diagnostics
sudo tailscale set --exit-node=<dev> # use dev host as exit node (lab VM)
sudo tailscale logout                # leave tailnet (revokes this device)
```

MagicDNS gives every node a hostname like `dev.tailnet-foo.ts.net`; you can also use the short form `dev` once MagicDNS is enabled (Settings → DNS).

## Troubleshooting

- **Device shows up but ACL tag is missing** — check that the auth key has the tag pre-applied (Settings → Keys → re-create if needed). Tags can only be set at enrollment via auth key, OR by an admin in the console afterward.
- **Lab VM can reach dev host (shouldn't!)** — your ACL has an extra rule, or the VM enrolled with a wrong tag. `tailscale status --json | jq .Self.Tags` on the lab VM to confirm what tag it actually has.
- **Tailscale SSH refused on dev host** — confirm `--ssh` was passed at `tailscale up`. Run `sudo tailscale set --ssh=true` to fix without re-enrolling.
- **Mobile Remote Control fails on cellular** — that's an Anthropic/Claude Code path, not a Tailscale path. Check `claude remote-control` is running on the dev host and that the dev host has outbound HTTPS to `*.anthropic.com`.
- **`autoApprovers.exitNode` doesn't take effect** — exit-node advertisements still need an admin click in **Machines → [dev host] → Edit route settings** the first time. The auto-approver only avoids it for *future* re-enrollments of the same tag.
