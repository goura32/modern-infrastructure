variable "libvirt_uri" {
  description = "Libvirt connection URI."
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  description = "Existing libvirt storage pool used by this lab."
  type        = string
  default     = "default"
}

variable "libvirt_network" {
  description = "Existing libvirt NAT network used by this lab."
  type        = string
  default     = "default"
}

variable "vm_name" {
  description = "Name of the training VM."
  type        = string
  default     = "modern-infrastructure-vm"
}

variable "vm_vcpus" {
  description = "Number of virtual CPUs assigned to the training VM."
  type        = number
  default     = 2

  validation {
    condition     = var.vm_vcpus >= 1 && var.vm_vcpus <= 4
    error_message = "vm_vcpus must be between 1 and 4."
  }
}

variable "vm_memory_mib" {
  description = "Memory assigned to the training VM in MiB."
  type        = number
  default     = 4096

  validation {
    condition     = var.vm_memory_mib >= 1024 && var.vm_memory_mib <= 8192
    error_message = "vm_memory_mib must be between 1024 and 8192."
  }
}

variable "vm_disk_gib" {
  description = "Writable VM disk capacity in GiB."
  type        = number
  default     = 25

  validation {
    condition     = var.vm_disk_gib >= 20 && var.vm_disk_gib <= 40
    error_message = "vm_disk_gib must be between 20 and 40."
  }
}

variable "ubuntu_image_url" {
  description = "Pinned Ubuntu Server 26.04 cloud image URL."
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/resolute/release-20260823/ubuntu-26.04-server-cloudimg-amd64.img"
}

variable "ssh_user" {
  description = "User created by cloud-init and used by Ansible."
  type        = string
  default     = "ubuntu"
}

variable "ssh_public_key" {
  description = "Public key installed in the VM; provide it at runtime, never commit it."
  type        = string
  sensitive   = true

  validation {
    condition     = length(trimspace(var.ssh_public_key)) > 0
    error_message = "ssh_public_key must contain an SSH public key."
  }
}

variable "wait_for_ip_cidr" {
  description = "CIDR used while waiting for the VM's DHCP lease."
  type        = string
  default     = "192.168.122.0/24"
}

variable "libvirt_qemu_uid" {
  description = "UID of the libvirt QEMU service account on the training host."
  type        = string
}

variable "libvirt_qemu_gid" {
  description = "GID of the group used by the libvirt QEMU service on the training host."
  type        = string
}
