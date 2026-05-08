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

data "openstack_networking_network_v2" "ext" {
  name = "ext-floating1"
}

locals {
  dns_servers = ["83.166.143.51", "83.166.143.52"]

  networks = {
    dev = {
      cidr        = "10.10.10.0/24"
      description = "Dev host network"
    }
    "lab-linux" = {
      cidr        = "10.10.20.0/24"
      description = "Linux lab network"
    }
    "lab-windows" = {
      cidr        = "10.10.30.0/24"
      description = "Windows lab network"
    }
  }
}

resource "openstack_networking_network_v2" "this" {
  for_each       = local.networks
  name           = "${each.key}-net"
  admin_state_up = true
}

resource "openstack_networking_subnet_v2" "this" {
  for_each        = local.networks
  name            = "${each.key}-subnet"
  network_id      = openstack_networking_network_v2.this[each.key].id
  cidr            = each.value.cidr
  ip_version      = 4
  dns_nameservers = local.dns_servers
}

resource "openstack_networking_router_v2" "this" {
  for_each            = local.networks
  name                = "${each.key}-router"
  external_network_id = data.openstack_networking_network_v2.ext.id
  admin_state_up      = true
}

resource "openstack_networking_router_interface_v2" "this" {
  for_each  = local.networks
  router_id = openstack_networking_router_v2.this[each.key].id
  subnet_id = openstack_networking_subnet_v2.this[each.key].id
}

resource "openstack_networking_secgroup_v2" "this" {
  for_each    = local.networks
  name        = "${each.key}-sg"
  description = "${each.value.description}: Tailscale UDP/41641 ingress, default egress"
}

resource "openstack_networking_secgroup_rule_v2" "tailscale_v4" {
  for_each          = local.networks
  security_group_id = openstack_networking_secgroup_v2.this[each.key].id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "udp"
  port_range_min    = 41641
  port_range_max    = 41641
  remote_ip_prefix  = "0.0.0.0/0"
  description       = "Tailscale direct NAT traversal"
}

resource "openstack_networking_secgroup_rule_v2" "tailscale_v6" {
  for_each          = local.networks
  security_group_id = openstack_networking_secgroup_v2.this[each.key].id
  direction         = "ingress"
  ethertype         = "IPv6"
  protocol          = "udp"
  port_range_min    = 41641
  port_range_max    = 41641
  remote_ip_prefix  = "::/0"
  description       = "Tailscale direct NAT traversal (v6)"
}

output "network_ids" {
  value = { for k, v in openstack_networking_network_v2.this : k => v.id }
}

output "subnet_ids" {
  value = { for k, v in openstack_networking_subnet_v2.this : k => v.id }
}

output "router_ids" {
  value = { for k, v in openstack_networking_router_v2.this : k => v.id }
}

output "security_group_ids" {
  value = { for k, v in openstack_networking_secgroup_v2.this : k => v.id }
}

output "external_network_id" {
  value = data.openstack_networking_network_v2.ext.id
}
