# Ansible inventory

VMのIPアドレスは、このディレクトリへ保存しません。repository rootでOpenTofuのoutputから毎回取得し、末尾にカンマを付けたinline inventoryとしてAnsibleへ渡します。SSH agentまたはAnsibleが使える接続鍵も必要です。

```bash
VM_IP="$(tofu -chdir=tofu output -raw vm_ip)"
test -n "$VM_IP"
ansible-playbook \
  -i "${VM_IP}," \
  -u ubuntu \
  ansible/playbook.yml
```

カンマは、`VM_IP`の値をinventoryファイル名ではなく、1台分のhostリストとして扱わせるために必要です。これにより、destroy・再構築でIPが変わっても設定ファイルへの手入力が発生しません。
