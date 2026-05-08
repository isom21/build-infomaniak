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

variable "ts_authkey_lab_linux" {
  description = "Tailscale auth key tagged tag:lab-linux (preauthorized, reusable, ephemeral)"
  type        = string
  sensitive   = true
}

variable "flavor" {
  type    = string
  default = "a2-ram4-disk80-perf1"
}

variable "image_name" {
  type    = string
  default = "Ubuntu 24.04 LTS Noble Numbat"
}

variable "keypair_name" {
  type    = string
  default = "edr-dev"
}

data "openstack_networking_network_v2" "lab" {
  name = "lab-linux-net"
}
data "openstack_networking_subnet_v2" "lab" {
  name = "lab-linux-subnet"
}
data "openstack_networking_secgroup_v2" "lab" {
  name = "lab-linux-sg"
}
data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

locals {
  user_data = templatefile("${path.module}/../../cloud-init/lab-linux.yaml.tpl", {
    ts_authkey = var.ts_authkey_lab_linux
  })
}

resource "openstack_networking_port_v2" "lab" {
  name           = "lab-linux-port"
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
  name        = "lab-linux"
  image_id    = data.openstack_images_image_v2.ubuntu.id
  flavor_name = var.flavor
  key_pair    = var.keypair_name
  user_data   = local.user_data

  network {
    port = openstack_networking_port_v2.lab.id
  }
}

# Floating IP needed at bootstrap to reach Tailscale's coordination server.
# Once on the tailnet, traffic is via tailscaled; this IP can be removed
# in a hardening pass to enforce "labs only reach internet via dev exit node."
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
