# 実機検証ノート

検証日: 2026-09-12
検証ホスト: `training`
検証対象: trainingホスト内のlibvirt/KVM上の教材VMだけ

## 1. 前提と導入

確認したtrainingホストの状態:

- Ubuntu Server 26.04.1 LTS
- 8 vCPU、約16 GiB RAM、約80 GiB disk
- `/dev/kvm`あり、CPU flagに`vmx`あり
- `training`ユーザーから`sudo -n true`が成功
- `ssh -A training`経由でguest用SSH agent forwardingを確認

trainingホストへ追加したのは、教材実行に必要なGit、QEMU/KVM、libvirt、OpenTofu、Ansible等のpackage・CLI、`training`ユーザーの`libvirt,kvm` group所属、既存default network/poolの確認・起動/autostart（必要時の保存先directory・pool準備）です。hostname、SSH設定、firewall、network topology、partition/filesystem layout、kernelは変更していません。`apt full-upgrade`、`dist-upgrade`、不要な再起動は実行していません。

導入・検証した主なCLI:

```text
git       2.53.0
tofu      1.12.6
ansible   core 2.21.4
virsh     12.0.0
qemu      10.2.1
```

Dockerはtrainingホストへ導入せず、Ansibleで教材VMへ導入しました。guestで確認したversionは次のとおりです。

```text
Docker Engine 29.8.0
Docker Compose v5.5.1
```

libvirtの既存`default` NAT networkを使い、bridge networkは追加していません。default storage poolは`/var/lib/libvirt/images`をtargetにして起動・autostartしました。

Ubuntu 26.04では`qemu-kvm` packageにAPT候補がなかったため、実際の導入には`qemu-system-x86`と`qemu-utils`を使いました。`libvirt-daemon-config-network`でdefault networkを用意し、`training`ユーザーを`libvirt,kvm` groupへ追加して再接続しました。

## 2. OpenTofu単体

`tofu/versions.tf`で`dmacvicar/libvirt` providerを`0.9.9`へ固定し、`.terraform.lock.hcl`を生成してGitへ含めました。

`tofu init`ではprovider registryにGPG keyが登録されていないため、signature validation skippedという表示が出ました。lock fileのversionとhashesは使用されますが、provider配布元の署名検証が完了したという意味ではありません。

provider以外の外部入力（Ubuntu cloud image、APT package、pipxのAnsible、Docker package、container image tag）は完全には固定していません。以下の再構築成功は、同じ前提条件と外部artifactが利用できる時点での結果であり、bit単位の再現性を示すものではありません。

Git archiveから展開したfresh directoryで次を実行し、成功しました。

```bash
tofu -chdir=tofu fmt -check -recursive
tofu -chdir=tofu init -input=false
tofu -chdir=tofu validate
tofu -chdir=tofu apply -input=false -auto-approve -no-color
```

apply結果:

```text
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
```

state listはdata sourceを含めて6行、実際の管理resourceは次の5つです。

- `libvirt_cloudinit_disk.init`
- `libvirt_volume.vm_disk`
- `libvirt_volume.cloudinit`
- `terraform_data.resize_vm_disk`
- `libvirt_domain.vm`

`tofu output -raw vm_ip`から、手入力なしで再構築ごとのVM IPを取得できました。DHCPで変わる値のため、IPアドレスは固定記録していません。

## 3. SSHとguest filesystem

OpenTofu outputのIPへSSH公開鍵認証で接続できました。cloud-initの完了状態は`status: done`でした。

最終guestのroot filesystem:

```text
/dev/vda1  ext4  24G  2.2G  21G  10% /
```

## 4. Ansible初回と冪等性

固定inventoryファイルへIPを書かず、次のinline inventoryを使用しました。

```bash
VM_IP="$(tofu -chdir=tofu output -raw vm_ip)"
ansible-playbook -i "${VM_IP}," -u ubuntu ansible/playbook.yml
```

初回Playbook結果:

```text
ok=17 changed=9 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0
```

初回に確認した内容:

- Docker公式APT repositoryのkeyringとsourcesを配置
- Docker Engine、Buildx、Compose pluginを導入
- Docker serviceをenable・start
- `ubuntu`を`docker` groupへ追加
- SSH connectionをresetして新しいsupplementary groupを反映
- allowlistしたApplication filesと`compose.yaml`を`/opt/modern-infrastructure/app`へ配置
- runtime `.env`をrepository外へ生成
- Compose modelを`docker compose config --quiet`で検証
- handlerでComposeをbuild・起動
- APIとDBへ`restart: unless-stopped`を設定
- `.dockerignore`、Dockerfile、Compose、requirements、`src/app.py`だけをallowlistで転送

同じPlaybookの2回目:

```text
ok=16 changed=0 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0
```

2回目はDocker repository、package、service、files、Composeを含め不要な変更がありませんでした。

## 5. Compose、HTTP、PostgreSQL

最終状態のCompose services:

```text
modern-infrastructure-api-1   Up ... (healthy)   0.0.0.0:8080->8080/tcp
modern-infrastructure-db-1    Up ... (healthy)   5432/tcp
```

trainingホストから次を実行しました。

```bash
curl --fail --silent "http://${VM_IP}:8080/health"
curl --fail --silent "http://${VM_IP}:8080/db"
```

結果:

```json
{"status": "ok", "service": "python-api"}
{"status": "ok", "database": "postgresql"}
```

`/db` endpointはAPIコンテナからPostgreSQLへ接続し、`SELECT 1`相当の確認を通過しています。PostgreSQLは教材を自己完結させるためComposeで実行しています。本番で必ずComposeを使うという判断ではありません。named volumeは同じVM内でのcontainer再作成向けで、`tofu destroy`ではVM diskと一緒にDBデータが失われ、backupにはなりません。

## 6. plan、destroy、Gitからの再構築

Compose構成後にOpenTofu planを実行しました。

```text
No changes. Your infrastructure matches the configuration.
```

その後、稼働中の教材VMを`tofu destroy -input=false -auto-approve`で削除しました。

```text
Destroy complete! Resources: 5 destroyed.
```

destroy直後に、教材domainと教材volumeが存在しないこと、libvirtのdefault network・default storage poolが残ることを確認しました。trainingホストの導入済みCLIとlibvirt serviceも残っています。

さらに、repositoryのHEADを`git archive`で`~/modern-infrastructure-final`へ展開し、元の作業directoryや固定inventoryに依存せず、同じ前提条件（default network/pool、SSH agent、実行時変数、外部repositoryへの接続）の上で次を再実行しました。archiveには既存Infrastructureのstateは含まれないため、新しいstateと教材VMを作成する検証です。

```text
tofu fmt -check / init / validate / apply       成功
OpenTofu apply                                  5 added
SSH + cloud-init                                成功
Ansible 初回                                    ok=17, changed=9, failed=0
Compose api/db                                  healthy
/health                                         HTTP成功
/db                                             PostgreSQL接続成功
Ansible 2回目                                  ok=16, changed=0, failed=0
tofu plan                                      No changes
```

## 7. 問題と修正

### qcow2内部容量

Ubuntu cloud imageをvolumeへuploadすると、libvirt volumeのcapacityが25 GiBでも、qcow2ヘッダのguest virtual sizeが初期サイズのままでした。`terraform_data.resize_vm_disk`で、volume作成後に対象diskだけへ次の一回限りのInfrastructure操作を行いました。

```text
sudo -n qemu-img resize <managed-volume-path> 25G
```

その後、cloud-initの`resize_rootfs: true`でguestのpartition/filesystemが拡張され、root filesystem 24 GiBを確認しました。guestへshellを送り込む`remote-exec`は使っていません。

### libvirt/AppArmor環境差

Ubuntu 26.04.1、libvirt 12.0.0、provider 0.9.9、Nested KVMの組み合わせで、domainのdisk sourceに`volume`を使うと、POSIX権限を設定していてもQEMU起動時にAppArmorから`Permission denied`を受けました。他のversion・環境へ同じ結果を一般化できるかは確認していません。

VM diskのowner/group/modeはlibvirtのQEMU service accountへ明示しています。さらにprovider 0.9.9の`source.file`で、管理対象volumeの絶対pathをVM diskとcloud-init ISOの両方へ渡す一時VMを作成しました。`sec_label`を指定しなくてもapplyに成功し、domain XMLはdynamic AppArmor labelとfile sourceになりました。最終構成はこの方式を採用し、host全体のAppArmorを無効化・変更していません。

`sec_label = [{ type = "none" }]`は通常のlibvirt利用に必須ではなく、最終コードへ残していません。security labelingを弱めるため、本番VMの一般的な回避策としてコピーしてはいけません。

### APT cache

Docker repository追加直後のpackage taskに`cache_valid_time`を残すと、repository追加前のfreshなAPT cacheを再利用してpackageが見つからない場合がありました。repository追加後のDocker package taskではAPT indexを必ず更新するようにしました。

### Docker group

同じAnsible接続のままDocker groupを追加すると、handlerのDocker socketアクセスに古いgroup情報が使われました。group追加直後に`meta: reset_connection`を実行し、非rootの`ubuntu`ユーザーでComposeを実行できるようにしました。

### PostgreSQL 18のvolume mount

`postgres:18-alpine`ではmajor version別のdata directoryを扱うため、volumeを`/var/lib/postgresql`へmountしました。旧`/var/lib/postgresql/data`では初期化に失敗しました。

追加レビュー後のfresh archiveでも、allowlist転送、Composeのrestart policy、`/health`、`/db`、DB停止時の固定503応答と復旧を確認しました。`TF_VAR_vm_disk_gib=26`のplanでは`terraform_data.resize_vm_disk`のreplacementを確認し、容量変更時もresize処理が再評価されます。検証後の最終destroyは`Resources: 5 destroyed`で、教材domain・専用volumeはなく、default network/poolは維持されています。

## 8. Git・秘密情報チェック

local repositoryの最終状態:

```text
branch: main
working tree: clean
tracked files: 19
provider lock file mode: 644
```

次を確認しました。

- `tofu/.terraform.lock.hcl`はtracked
- `.terraform/`、tfstate、tfplan、tfvarsはignore
- `app/.env`はignore
- runtime passwordはcontrollerのcacheとVM上の`.env`だけに置き、repositoryへ書き込まない。VMを残したままcontroller cacheを削除しない
- SSH private key、password、API key、tokenはrepository・validation notesへ書き込まない

providerのstateはtraining側の作業directoryに残り得ますが、Gitへは追加していません。stateには接続情報やcloud-init由来の値など機密性のある情報が含まれ得るため、backendを使う場合もアクセス制御と暗号化を検討します。
