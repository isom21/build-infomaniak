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

variable "ts_authkey_dev" {
  description = "Tailscale auth key tagged tag:dev (preauthorized, non-reusable, non-ephemeral)"
  type        = string
  sensitive   = true
}

variable "flavor" {
  description = "OpenStack flavor for the dev host. Note: dc4-a only offers perf1 boot disks; perf2/3/4 are available as Cinder volume types for attached storage."
  type        = string
  default     = "a8-ram32-disk80-perf1"
}

variable "image_name" {
  description = "Glance image name"
  type        = string
  default     = "Ubuntu 24.04 LTS Noble Numbat"
}

variable "keypair_name" {
  description = "OpenStack keypair name (already uploaded)"
  type        = string
  default     = "edr-dev"
}

# Look up resources created by ../network/
data "openstack_networking_network_v2" "dev" {
  name = "dev-net"
}
data "openstack_networking_subnet_v2" "dev" {
  name = "dev-subnet"
}
data "openstack_networking_secgroup_v2" "dev" {
  name = "dev-sg"
}
data "openstack_networking_network_v2" "ext" {
  name = "ext-floating1"
}

data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

locals {
  # Private key for dev → lab SSH. Same keypair the labs trust (via
  # OpenStack keypair injection on lab-linux, via authorized_keys install
  # on lab-windows). Base64-encoded for cloud-init's write_files.
  ssh_private_key_b64 = base64encode(file("${path.module}/../../../secrets/edr-dev.key"))

  user_data = templatefile("${path.module}/../../cloud-init/dev.yaml.tpl", {
    ssh_pubkey          = trimspace(file("${path.module}/../../../secrets/edr-dev.key.pub"))
    ssh_private_key_b64 = local.ssh_private_key_b64
    ts_authkey          = var.ts_authkey_dev
  })
}

# Port on dev-net with the dev-sg
resource "openstack_networking_port_v2" "dev" {
  name           = "dev-port"
  network_id     = data.openstack_networking_network_v2.dev.id
  admin_state_up = true

  fixed_ip {
    subnet_id = data.openstack_networking_subnet_v2.dev.id
  }

  security_group_ids = [
    data.openstack_networking_secgroup_v2.dev.id,
  ]
}

resource "openstack_compute_instance_v2" "dev" {
  name      = "dev"
  image_id  = data.openstack_images_image_v2.ubuntu.id
  flavor_name = var.flavor
  key_pair  = var.keypair_name
  user_data = local.user_data

  network {
    port = openstack_networking_port_v2.dev.id
  }

  # Cloud-init runs every package install + Tailscale + Docker + Rust + Node.
  # Long but idempotent; first boot takes ~5 min.
}

# Floating IP for outbound internet (Tailscale install, apt, etc).
resource "openstack_networking_floatingip_v2" "dev" {
  pool = "ext-floating1"
}

resource "openstack_networking_floatingip_associate_v2" "dev" {
  floating_ip = openstack_networking_floatingip_v2.dev.address
  port_id     = openstack_networking_port_v2.dev.id
}

output "instance_id" {
  value = openstack_compute_instance_v2.dev.id
}

output "fixed_ip" {
  value = [for ip in openstack_networking_port_v2.dev.fixed_ip : ip.ip_address][0]
}

output "floating_ip" {
  value = openstack_networking_floatingip_v2.dev.address
}
