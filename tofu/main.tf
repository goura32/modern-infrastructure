resource "libvirt_volume" "vm_disk" {
  name     = "${var.vm_name}.qcow2"
  pool     = var.libvirt_pool
  capacity = var.vm_disk_gib * 1024 * 1024 * 1024

  create = {
    content = {
      url = var.ubuntu_image_url
    }
  }

  target = {
    format = {
      type = "qcow2"
    }
    permissions = {
      owner = var.libvirt_qemu_uid
      group = var.libvirt_qemu_gid
      mode  = "0600"
    }
  }

}

resource "terraform_data" "resize_vm_disk" {
  triggers_replace = [libvirt_volume.vm_disk.id]

  provisioner "local-exec" {
    command = "sudo -n qemu-img resize '${libvirt_volume.vm_disk.path}' ${var.vm_disk_gib}G"
  }
}

resource "libvirt_cloudinit_disk" "init" {
  name = "${var.vm_name}-cloudinit"

  user_data = templatefile("${path.module}/cloud-init.yaml", {
    ssh_user       = var.ssh_user
    ssh_public_key = trimspace(var.ssh_public_key)
  })

  meta_data = yamlencode({
    instance-id    = var.vm_name
    local-hostname = var.vm_name
  })

  network_config = <<-YAML
    version: 2
    ethernets:
      all:
        match:
          name: "en*"
        dhcp4: true
  YAML
}

resource "libvirt_volume" "cloudinit" {
  name = "${var.vm_name}-cloudinit.iso"
  pool = var.libvirt_pool

  create = {
    content = {
      url = libvirt_cloudinit_disk.init.path
    }
  }
}

resource "libvirt_domain" "vm" {
  name        = var.vm_name
  type        = "kvm"
  memory      = var.vm_memory_mib
  memory_unit = "MiB"
  vcpu        = var.vm_vcpus

  # The training host's Ubuntu 26.04 AppArmor helper does not generate a
  # usable per-domain disk rule for this provider's volume XML. Keep this
  # exception scoped to the disposable lab VM; do not disable AppArmor host-wide.
  sec_label = [{ type = "none" }]
  features  = { acpi = true }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [{ dev = "hd" }]
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.vm_disk.pool
            volume = libvirt_volume.vm_disk.name
          }
        }
        target = {
          dev = "vda"
          bus = "virtio"
        }
        driver = {
          type = "qcow2"
        }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.cloudinit.pool
            volume = libvirt_volume.cloudinit.name
          }
        }
        target = {
          dev = "sda"
          bus = "sata"
        }
      }
    ]

    interfaces = [
      {
        type  = "network"
        model = { type = "virtio" }
        source = {
          network = {
            network = var.libvirt_network
          }
        }
        wait_for_ip = {
          timeout = 600
          source  = "lease"
          network = var.wait_for_ip_cidr
        }
      }
    ]
  }

  running = true

  depends_on = [terraform_data.resize_vm_disk]
}

data "libvirt_domain_interface_addresses" "vm" {
  domain = libvirt_domain.vm.name
  source = "lease"

  depends_on = [libvirt_domain.vm]
}
