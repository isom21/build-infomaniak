# Windows lab — SKELETON, not applied yet.
#
# Open items before this can be `terraform apply`d:
#   1. Verify cloudbase-init in the Glance image accepts our PowerShell
#      user_data format. Some Infomaniak Windows images require a specific
#      MIME structure or unattend.xml. If it doesn't pick it up, switch to
#      a Packer-baked image.
#   2. Set the dev host tailnet IP in cloud-init/lab-windows.yaml.tpl
#      kdnet block (currently commented out).
#   3. Confirm intra-tailnet ACL allows tag:dev → tag:lab-windows:50000/udp
#      (already true: ACL grants tag:dev → tag:lab-windows:* in main policy).
#
# To stage but not yet apply: `make lab-windows-init` then `make lab-windows-plan`.

terraform {
  required_version = ">= 1.5"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }
}

provider "openstack" {
  cloud = "PCP-9UAH2PR-dc4-a"
}

variable "ts_authkey_lab_windows" {
  description = "Tailscale auth key tagged tag:lab-windows (preauthorized, reusable, ephemeral)"
  type        = string
  sensitive   = true
}

variable "flavor" {
  type    = string
  default = "a4-ram16-disk80-perf1"
}

# Locked image ID for stability — see 02-architecture.md "Verified provisioning details"
variable "windows_image_id" {
  type    = string
  default = "28039fe3-0a79-4ed8-8d30-e3310e6aa7cc"
}

variable "keypair_name" {
  type    = string
  default = "edr-dev-rsa"  # cloudbase-init's password-encryption plugin requires RSA
}

data "openstack_networking_network_v2" "lab" {
  name = "lab-windows-net"
}
data "openstack_networking_subnet_v2" "lab" {
  name = "lab-windows-subnet"
}
data "openstack_networking_secgroup_v2" "lab" {
  name = "lab-windows-sg"
}

locals {
  # Public keys that get installed as Administrator's authorized_keys so SSH
  # works without password from any host that has the matching private key.
  # edr-dev.key.pub      = ed25519 keypair (also used for OpenStack lab-linux SSH)
  # edr-dev-rsa.key.pub  = RSA keypair (also used for cloudbase-init password encrypt)
  ssh_pubkeys = join("\n", [
    trimspace(file("${path.module}/../../../secrets/edr-dev.key.pub")),
    trimspace(file("${path.module}/../../../secrets/edr-dev-rsa.key.pub")),
  ])

  inner_script = templatefile("${path.module}/../../cloud-init/lab-windows-inner.ps1.tpl", {
    ts_authkey  = var.ts_authkey_lab_windows
    ssh_pubkeys = local.ssh_pubkeys
  })
  user_data = templatefile("${path.module}/../../cloud-init/lab-windows.yaml.tpl", {
    inner_b64 = base64encode(local.inner_script)
  })
}

resource "openstack_networking_port_v2" "lab" {
  name           = "lab-windows-port"
  network_id     = data.openstack_networking_network_v2.lab.id
  admin_state_up = true

  fixed_ip {
    subnet_id = data.openstack_networking_subnet_v2.lab.id
  }

  security_group_ids = [
    data.openstack_networking_secgroup_v2.lab.id,
  ]
}

resource "openstack_compute_instance_v2" "lab" {
  name        = "lab-windows"
  image_id    = var.windows_image_id
  flavor_name = var.flavor
  key_pair    = var.keypair_name
  user_data   = local.user_data

  network {
    port = openstack_networking_port_v2.lab.id
  }
}

resource "openstack_networking_floatingip_v2" "lab" {
  pool = "ext-floating1"
}

resource "openstack_networking_floatingip_associate_v2" "lab" {
  floating_ip = openstack_networking_floatingip_v2.lab.address
  port_id     = openstack_networking_port_v2.lab.id
}

output "instance_id" {
  value = openstack_compute_instance_v2.lab.id
}

output "floating_ip" {
  value = openstack_networking_floatingip_v2.lab.address
}
