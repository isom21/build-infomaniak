# Terraform — shared networking

Defines the three Neutron tenant networks (`dev-net`, `lab-linux-net`,
`lab-windows-net`), one router per network attached to `ext-net1`, and three
security groups allowing Tailscale UDP/41641 ingress.

## Usage

```bash
export OS_CLIENT_CONFIG_FILE=/mnt/d/priv/code/PCU-9UAH2PR-clouds.yaml
terraform init
terraform plan
terraform apply
```

## Outputs

`terraform output` exposes:

- `network_ids` — `dev`, `lab-linux`, `lab-windows`
- `subnet_ids` — same keys
- `router_ids` — same keys
- `security_group_ids` — same keys
- `external_network_id` — Infomaniak `ext-net1`

The dev/lab Terraform stacks (planned) consume these via `terraform_remote_state`.

## Notes

- All three networks have a router to `ext-net1`. Strict "labs only reach
  internet via dev exit node" requires removing the lab routers and
  configuring Tailscale `--exit-node=tag:dev` on the lab VMs — deferred until
  Phase 5 of the build plan, since labs need internet to bootstrap Tailscale
  itself.
- The default OpenStack security group is automatically attached to every
  VM in addition to whatever you specify; it allows intra-SG traffic and
  default egress, which is fine for our design.
- DNS servers point at Infomaniak's public resolvers.
