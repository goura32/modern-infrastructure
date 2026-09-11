# 現代的なインフラ入門

Linux / SSH、Git、Docker、Docker Compose、Ansible、OpenTofu、libvirt / KVMを一つの小さな環境で学ぶ教材です。

詳細な説明は[教材本体](modern-infrastructure-introduction.md)、実機で確認した結果は[validation-notes.md](validation-notes.md)にあります。

## 想定読者

Linux CLIを多少使ったことがあり、Docker、Ansible、OpenTofu、libvirt / KVM、Infrastructure as Codeを体系的に学びたい初学者を想定しています。

## 学ぶ責務分離

```text
OpenTofu                 VM・ディスク・既存libvirt networkへの接続
    ↓
Ansible                  Ubuntu OS・package・Docker・設定
    ↓
Docker / Docker Compose  Python Web API + PostgreSQL
```

Gitへ保存したcommit済みコードから、同じ前提条件の上で新しい教材VMを再構築します。既存VMの更新・destroyには、その環境のOpenTofu stateが必要です。

## 対象環境

- 検証ホスト: `training`
- OS: Ubuntu Server 26.04 LTS
- KVM: 利用可能
- 接続: SSH公開鍵認証
- VM: Ubuntu Server、2 vCPU、4 GiB RAM、25 GiB virtual disk
- network: 既存のlibvirt `default` NAT network

trainingホスト自身はOpenTofuの管理対象ではありません。教材用VMだけをOpenTofuで作成・破棄します。前提セットアップでは必要なpackage・CLIを追加し、`training`ユーザーを`libvirt,kvm` groupへ追加し、既存のdefault network/poolを確認して必要なら起動・autostartします（poolがなければ保存先directoryとpoolを準備します）。hostname、SSH設定、firewall、network topology、partition/filesystem layout、kernelは変更しません。`apt full-upgrade`と`dist-upgrade`、不要な再起動は行いません。

## ディレクトリ

```text
modern-infrastructure/
├── README.md
├── modern-infrastructure-introduction.md
├── validation-notes.md
├── .gitignore
├── tofu/
│   ├── versions.tf
│   ├── providers.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── cloud-init.yaml
│   └── .terraform.lock.hcl
├── ansible/
│   ├── inventory/README.md
│   └── playbook.yml
└── app/
    ├── compose.yaml
    ├── Dockerfile
    ├── requirements.txt
    ├── .dockerignore
    ├── .env.example
    └── src/app.py
```

`tofu/`はInfrastructure、`ansible/`はVMのOS・ミドルウェア、`app/`はApplicationを担当します。

## クイックスタート

以下は`training`へSSH接続した後の手順です。SSH agentに、VMへ登録してよい公開鍵が読み込まれている必要があります。秘密鍵の内容は表示・保存しません。

### 1. trainingへ接続して前提を確認

```bash
ssh -A training
cd ~/modern-infrastructure

export PATH="$HOME/.local/bin:$PATH"
test -e /dev/kvm
virsh -c qemu:///system version
virsh -c qemu:///system net-info default
virsh -c qemu:///system pool-info default
```

`default` storage poolが存在しない場合だけ、次を実行します。

```bash
sudo install -d -m 0755 /var/lib/libvirt/images
virsh -c qemu:///system pool-info default >/dev/null 2>&1 \
  || sudo virsh pool-define-as default dir --target /var/lib/libvirt/images
sudo virsh pool-start default 2>/dev/null || true
sudo virsh pool-autostart default
```

OpenTofu、Ansible、libvirtが未導入のクリーン環境では、本文の「Phase 2」を先に実行してください。

### 2. 実行時の変数を設定

```bash
export TF_VAR_ssh_public_key="$(ssh-add -L | awk 'NR == 1 { print; exit }')"
export TF_VAR_libvirt_qemu_uid="$(id -u libvirt-qemu)"
export TF_VAR_libvirt_qemu_gid="$(getent group kvm | cut -d: -f3)"
test -n "$TF_VAR_ssh_public_key"
```

公開鍵とUID/GIDは実行時にだけ使います。公開鍵をこのREADMEへ書き込まず、秘密鍵は絶対に`TF_VAR_ssh_public_key`へ入れません。

### 3. OpenTofuでVMを作成

```bash
tofu -chdir=tofu fmt -recursive
tofu -chdir=tofu init -input=false
tofu -chdir=tofu validate
tofu -chdir=tofu plan -input=false
tofu -chdir=tofu apply -input=false -auto-approve
```

`tofu plan`で対象が教材VM、専用volume、cloud-init disk、disk拡張用の補助resourceだけであることを確認します。`apply`後、IPをoutputから取得します。

```bash
VM_IP="$(tofu -chdir=tofu output -raw vm_ip)"
printf '%s\n' "$VM_IP"
ssh-keygen -R "$VM_IP" >/dev/null 2>&1 || true
ssh -o StrictHostKeyChecking=accept-new ubuntu@"$VM_IP" \
  'id; hostname; sudo -n true'
```

IPアドレスはinventoryへ転記しません。

### 4. AnsibleでVMを構成

```bash
ansible-playbook \
  -i "${VM_IP}," \
  -u ubuntu \
  ansible/playbook.yml
```

PlaybookはDocker公式APT repository、Docker Engine、Compose plugin、`docker` group、Application files、Compose serviceをVMへ設定します。DB passwordはrepository外のcontroller cacheから生成します。controller cacheとVM内のPostgreSQL volumeは同じpasswordを前提にするため、VMを残したままcacheを削除しないでください。

### 5. APIとPostgreSQLを確認

```bash
ssh ubuntu@"$VM_IP" \
  'cd /opt/modern-infrastructure/app && docker compose -p modern-infrastructure ps && docker compose -p modern-infrastructure config --quiet'

curl --fail --silent "http://${VM_IP}:8080/health"
printf '\n'
curl --fail --silent "http://${VM_IP}:8080/db"
printf '\n'
```

`/health`はAPIの応答、`/db`はAPIからPostgreSQLへの`SELECT 1`が成功した応答です。

### 6. 冪等性とplanを確認

```bash
ansible-playbook -i "${VM_IP}," -u ubuntu ansible/playbook.yml
tofu -chdir=tofu plan -input=false
```

Ansible 2回目のrecapが`changed=0 failed=0 unreachable=0`であり、OpenTofuが`No changes`であることを確認します。

### 7. destroyと再構築

```bash
tofu -chdir=tofu destroy -input=false -auto-approve
virsh -c qemu:///system list --all
tofu -chdir=tofu state list
```

stateが空になり、教材VMだけが消えたことを確認します。trainingホストのOpenTofu、Ansible、libvirt package、default network、default poolは残します。

その後、同じ前提条件（default network/pool、SSH agent、実行時変数）がある環境で、Gitのcommit済みコードから「3. OpenTofuでVMを作成」以降を再実行します。destroy済みの新しいVMを作る場合は新しいstateが作られます。最終的に`/health`と`/db`が再び成功すれば、再構築完了です。

## Git管理

commitするもの:

```text
*.tf
.terraform.lock.hcl
Ansible YAML
Dockerfile
compose.yaml
Application source
README・教材本文・検証ノート
.gitignore
```

commitしないもの:

```text
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
.env
秘密鍵、password、API key、token
一時生成ファイル
```

`app/.env.example`は例なのでcommitできますが、実際の`app/.env`はcommitしません。OpenTofu stateにはcloud-init user-dataなどが含まれる可能性があるため、stateも秘密情報として扱います。

provider `0.9.9`とlock fileは固定していますが、Ubuntu cloud image、APT package、pipxのAnsible、Docker package、container image tagは外部から取得します。日付付きURLを使っていても、完全なbit単位の再現性までは保証しません。本番ではchecksum、image digest、package repository snapshotなどを別途固定します。

## 役割の境界

- OpenTofu: VM、network接続、disk、libvirt resource。
- Ansible: OS package、user/group、Docker導入、設定ファイル、service。
- Docker / Compose: Application image、API、PostgreSQL、container network・volume。

OpenTofuの`remote-exec`へ大量のshellを入れません。AnsibleだけでVMを作りません。Application imageの定義は`app/`が所有し、AnsibleはComposeのbuild・startを起動します。ComposeでhostのSSHやsystemdを管理しません。

## 注意

- PostgreSQLをComposeで動かすのは教材を自己完結させるためです。本番でも必ずComposeでDBを運用すべきという意味ではありません。
- named volumeは同じVM内でcontainerを作り直す間の保存領域です。`tofu destroy`ではVM diskごと削除されるため、DBデータも失われます。named volumeはbackupではありません。残す必要があるデータは`pg_dump`などで退避します。
- `tofu/main.tf`では`sec_label = [{ type = "none" }]`を使いません。この環境で確認した`source.volume`のAppArmor問題は、providerの`source.file`で解決し、dynamic security labelingを維持しています。`type = "none"`は通常必須ではなく、本番設定へコピーしません。
- `docker` groupはDocker daemonを通じてhostを操作できる強い権限です。教材VMの学習者用設定であり、信頼できないユーザーが共用する本番hostへそのまま適用しません。
- APIは学習用の未認証HTTP endpointで、`8080:8080`によりVMの全interfaceへ公開します。本番では認証・TLS・到達範囲の制限を設計します。
- 使い捨てVMではIP再利用時の古いhost keyを`ssh-keygen -R`で除去します。本番ではhost keyを確認してから接続します。
- `docker compose down -v`はDB volumeを削除します。データを残す実験では`docker compose down`だけを使います。
- Kubernetes、Helm、GitOps、Packer、Vault、CI/CDは本教材の詳細範囲外です。本文の「次に学ぶもの」で位置付けだけ説明します。

## ファイル別の入口

- 概念、理由、全手順: [modern-infrastructure-introduction.md](modern-infrastructure-introduction.md)
- 実機検証の事実、修正履歴、完了条件: [validation-notes.md](validation-notes.md)
- OpenTofuとlibvirt: [`tofu/`](tofu/)
- Ansibleとinline inventory: [`ansible/`](ansible/)
- Python APIとCompose: [`app/`](app/)

## License

この教材は[MIT License](LICENSE)で公開しています。
