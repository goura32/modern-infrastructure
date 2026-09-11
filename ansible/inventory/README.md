# Inventory

The VM address is intentionally not stored here. After `tofu apply`, pass the
OpenTofu output as a one-host, comma-terminated inline inventory:

```bash
VM_IP=$(tofu -chdir=tofu output -raw vm_ip)
ansible-playbook -i "${VM_IP}," -u ubuntu ansible/playbook.yml
```

The comma tells Ansible that the value is an inline host list rather than a
filename.
