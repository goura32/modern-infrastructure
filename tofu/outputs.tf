locals {
  vm_ipv4_addresses = flatten([
    for interface in data.libvirt_domain_interface_addresses.vm.interfaces : [
      for address in interface.addrs : address.addr
      if address.type == "ipv4"
    ]
  ])
}

output "vm_name" {
  description = "Managed libvirt domain name."
  value       = libvirt_domain.vm.name
}

output "vm_ip" {
  description = "First IPv4 address reported by the libvirt DHCP lease."
  value       = try(local.vm_ipv4_addresses[0], "")
}

output "vm_ipv4_addresses" {
  description = "All IPv4 addresses reported by the libvirt DHCP lease."
  value       = local.vm_ipv4_addresses
}

output "ssh_user" {
  description = "SSH user created by cloud-init."
  value       = var.ssh_user
}
