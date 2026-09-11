# 現代的なインフラ入門

対象: Linux CLI経験者向けの初学者教材
検証基準日: 2026-09-12
検証環境: `training`（Ubuntu Server 26.04 LTS、KVM利用可能）

Ubuntu 26.04のリリース情報は公式release notesで確認できます。[3]

## この教材のゴール

この教材の最後では、Gitに保存したcommit済みコードを使い、同じ前提条件の上で新しい環境を何度も作り直します。既存Infrastructureの更新・destroyには、その環境のOpenTofu stateが必要です。

```text
training host
      │
      │ OpenTofu
      ▼
libvirt / KVM
      │
      ▼
Ubuntu VM
      │
      │ Ansible over SSH
      ▼
OS・Docker構成済みVM
      │
      │ docker compose
      ▼
Python Web API ─── PostgreSQL
```

IaC（Infrastructure as Code）とは、サーバーやネットワークなどのInfrastructureをコードで定義し、同じ定義から再現する考え方です。この教材では、単にコマンドを打てるようになるのではなく、「どの変更を、どの層のコードに書くべきか」を判断できることを目指します。

## 1. 全体像と責務分離

### 1.1 三つの道具を三つの責務に分ける

```text
OpenTofu
  VM・ディスク・既存libvirt networkへの接続などのInfrastructure
          │
          ▼
Ansible
  OS package・user/group・設定ファイル・service
          │
          ▼
Docker / Docker Compose
  Application image・API・PostgreSQL・container構成
```

- OpenTofuはInfrastructureを作る。
- Ansibleは作られたVMのOSとミドルウェアを構成する。
- Docker Composeは、構成済みのDocker Engine上でApplicationを動かす。

例えば「DockerをVMへインストールする」はAnsibleの仕事です。「PostgreSQL containerを起動する」はComposeの仕事です。OpenTofuの`remote-exec`へ大量のshell処理を詰め込むと、InfrastructureとOS構成が混ざり、差分の理由を追いにくくなります。

### 1.2 まず手作業、次にコード化

最初にLinux上でファイルを作り、serviceを調べ、containerを起動します。その操作を理解してから、同じ結果をAnsible、Compose、OpenTofuへ移します。

```text
手作業で結果を観察する
        ↓
何を宣言すべきか決める
        ↓
コードにする
        ↓
同じコードを再実行して差分を確認する
```

### 1.3 用語

- **Infrastructure**: VM、仮想ネットワーク、ディスクなど、Applicationを載せる土台。
- **OS構成**: package、user、設定ファイル、systemd serviceなどの状態。
- **Application**: APIやDBなど、利用者に機能を提供するソフトウェア。
- **宣言的**: 「最終的にこの状態にする」と書き、具体的な手順の全てを書かない方式。
- **冪等性（idempotence）**: 同じコードを繰り返しても、既に目的の状態なら不要な変更が起きない性質。

### ここまでで理解しておくこと

- OpenTofu、Ansible、Composeは競合する道具ではなく、層が違う。
- VMを作る処理と、VMの中を設定する処理を混ぜない。
- 手作業の観察がコード化の出発点になる。

## 2. Linux / SSH

### 2.1 Linuxの状態を読む

Linuxでは、ファイル、プロセス、service、環境変数などをコマンドで調べます。最初から全てを覚える必要はありません。「今どの層を見ているか」を意識します。

```bash
pwd
ls -la
printf '%s\n' "$HOME"
env | sort
```

- `pwd`: 現在のディレクトリ。
- `ls -la`: 隠しファイルを含む一覧。
- `env`: プロセスへ渡された環境変数。
- `$HOME`のような値: shellが展開する環境変数。

ファイルとディレクトリの権限は、誰が読めるか、書けるか、実行できるかを決めます。

```bash
mkdir -p ~/infra-practice
printf 'hello\n' > ~/infra-practice/hello.txt
chmod 600 ~/infra-practice/hello.txt
ls -l ~/infra-practice/hello.txt
```

`chmod 600`は所有者だけに読み書きを許可します。`chown`は所有者とグループを変更しますが、他人のファイルを勝手に変更するためのコマンドではありません。変更前に`ls -l`で対象を確認します。

### 2.2 packageとservice

Ubuntuの`apt`はpackageをインストール・更新・削除する仕組みです。`systemctl`はsystemd serviceの状態を操作し、`journalctl`はログを読みます。

```bash
sudo apt update
apt-cache policy openssh-server
systemctl status ssh --no-pager
journalctl -u ssh -n 30 --no-pager
```

`apt update`はpackage一覧を更新します。`apt upgrade`などの更新範囲とは別の処理です。この教材では、trainingホストで`apt full-upgrade`や`dist-upgrade`を実行しません。

### 2.3 SSH公開鍵認証

SSHは、遠隔のLinuxへ安全に接続するためのプロトコルです。公開鍵認証では、次の二つを使います。

```text
手元: 秘密鍵  ──証明には使うが、相手へ渡さない
      公開鍵  ──接続先の ~/.ssh/authorized_keys に登録
```

秘密鍵をGitやチャットへ貼り付けてはいけません。今回の検証では、trainingへの接続で使えるSSH agentから公開鍵を読み取り、OpenTofuの実行時変数へ渡します。秘密鍵ファイルの内容を表示・保存する手順は使いません。

```bash
ssh -A training
ssh-add -L
```

`ssh-add -L`が公開鍵を表示します。表示内容をログへ保存しないでください。`ssh -A`はagent forwardingを有効にします。環境のSSH aliasがagent forwardingを既に有効にしている場合は`ssh training`でも構いません。

教材の再構築では、IP再利用時にhost keyが変わることがあるため`accept-new`と`ssh-keygen -R`を使います。これは使い捨てVM向けの簡略化です。本番では接続先のfingerprintを確認してからknown_hostsを更新します。

接続後は、次のように接続先のidentityと権限を確認します。

```bash
ssh ubuntu@"$VM_IP" 'id; hostname; sudo -n true; systemctl is-system-running || true'
```

この例は、接続先のIPをshell変数`VM_IP`へ設定済みの場合の書き方です。統合手順では、OpenTofuのoutputから同じ変数を設定します。

`sudo`は管理者権限で一時的に処理を実行する仕組みです。`sudo -n true`はパスワード入力なしでsudoできるかを確認します。

この教材では手順を簡単にするため`ubuntu`へ`NOPASSWD:ALL`を設定しています。本番では必要な操作だけに権限を絞ります。

### ここまでで理解しておくこと

- Linuxの状態はファイル、service、ログ、環境変数として観察できる。
- SSH公開鍵認証では、秘密鍵を接続先やrepositoryへ置かない。
- `apt`、`systemctl`、`journalctl`は役割が異なる。

## 3. Git

### 3.1 Gitの三つの場所

Gitは、コードの変更履歴を保存する分散バージョン管理システムです。用語を場所と結び付けます。[25]

```text
working tree       今編集しているファイル
      │ git add
      ▼
staging area       次のcommit候補
      │ git commit
      ▼
repository         履歴として保存されたcommit
```

- **repository**: Gitの履歴を持つ場所。
- **working tree**: 作業中のファイル一式。
- **commit**: ある時点の変更を識別する履歴。
- **diff**: 変更前後の差分。
- **branch**: 履歴を分けて作業する名前付きの参照。

### 3.2 小さく変更して確認する

```bash
git status
git diff
git diff --check
git branch --show-current
```

`git diff`を読まずにcommitすると、不要なファイルや秘密情報を含める危険があります。変更を確認した後に、対象を明示してstageします。[27]

```bash
git add tofu/main.tf ansible/playbook.yml app/compose.yaml
git diff --cached
git commit -m 'Add infrastructure learning environment'
```

ブランチは実験的な変更を分ける道具です。GitHub固有の機能を使わなくても、ローカルrepositoryだけでこの教材の目的は達成できます。

### 3.3 `.gitignore`と秘密情報

`.gitignore`は、意図せずGitへ追加しないファイルのパターンを定義します。[26]

このrepositoryでは、次を含めません。

```text
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
.env
秘密鍵、password、API key、token、一時生成ファイル
```

次は含めます。

```text
*.tf
.terraform.lock.hcl
Ansible YAML
Dockerfile
compose.yaml
Application source
README、教材本文、.gitignore
```

`.gitignore`は既にcommitされた秘密情報を消去する機能ではありません。秘密情報をcommitした場合は、まず漏えいしたものとして無効化・交換し、履歴からの除去を別途検討します。

### ここまでで理解しておくこと

- working treeの変更を`diff`で確認してからcommitする。
- IaCのコードもApplication sourceと同じく履歴管理する。
- state、`.env`、秘密鍵はrepositoryへ入れない。

## 4. Docker

### 4.1 ImageとContainer

Dockerの**image**は、Applicationを実行するための読み取り専用に近いパッケージです。**container**は、そのimageから作られた実行中のプロセスです。

```text
Dockerfile ──build──> Image ──run──> Container
                                         │
                           port / volume / environment
```

DockerfileにApplicationの実行環境を記述します。Registryはimageを保存・配布する場所です。今回のAPIはPython imageを基礎にして、依存packageとsourceを組み込みます。

### 4.2 VMとの違い

VMは仮想ハードウェア上でOS kernelを起動します。Containerはhostのkernelを共有し、プロセスを隔離して実行します。

```text
VM:        guest OS kernel + process
Container: host kernel + isolated process
```

VMはOS境界を作るのに向き、containerはApplicationの配布単位をそろえるのに向きます。今回の責務分離では、VMをOpenTofuで作り、そのVMの中でDocker Composeを動かします。

### 4.3 APIを単体で動かす

`app/Dockerfile`は、APIを8080/tcpで待ち受けるimageを作ります。APIの`/health`はDBを使わず応答し、`/db`はPostgreSQLへ接続して`SELECT 1`を実行します。

ここからの手作業は、Dockerが導入済みのローカル環境で行う任意演習です。trainingホストにはDockerを導入しません。統合手順では、AnsibleでDockerを導入した後の教材VM内で実行します。

```bash
cd app
docker build -t modern-infrastructure-api:local .
docker run --rm -d --name api-manual -p 8080:8080 \
  modern-infrastructure-api:local
curl --fail http://127.0.0.1:8080/health
docker stop api-manual
```

ここではDBなしでも動く`/health`だけを確認します。DBを含む実行は次章のComposeで行います。

### 4.4 port、network、volume、environment variable

- **port**: hostとcontainerの通信口を対応付ける。例: `8080:8080`。
- **network**: container同士が名前で通信するための仮想ネットワーク。
- **volume**: containerを削除してもデータを残すための保存領域。
- **environment variable**: imageを変更せず設定値を渡す仕組み。

DB passwordのような値はDockerfileへ埋め込みません。Composeの`.env`へ分離し、Git管理から外します。

### ここまでで理解しておくこと

- Dockerfileはimageを作る材料、containerは実行中のプロセス。
- VMとcontainerは隔離の境界とkernelの扱いが異なる。
- port、network、volume、environment variableは別の責務を持つ。

## 5. Docker Compose

### 5.1 複数containerを一つのアプリケーションとして扱う

Composeは、複数containerのサービス、network、volume、環境変数をYAMLで定義します。Compose仕様は、サービスやvolumeなどの構成要素を定義しています。[6][8]

標準ファイル名は`compose.yaml`、CLIは`docker compose`です。旧来の`docker-compose`を標準手順にはしません。[5]

```text
compose.yaml
   ├─ api  Python Web API
   └─ db   PostgreSQL
             │
             └─ named volume postgres-data
```

`api`からDBへ接続するときのhostnameは、hostのIPではなくCompose service名`db`です。Composeが作るnetwork上で名前解決されます。

### 5.2 この教材のCompose構成

`app/compose.yaml`の要点は次の通りです。

- `api`はDockerfileからbuildし、hostの8080番portへ公開する。
- `db`はPostgreSQL imageを使い、named volumeへデータを保存する。
- `db`のhealthcheckが成功してから`api`を起動する。
- DB passwordなどは`.env`から読み込む。

このlabのAPIは認証・TLSなしで、`8080:8080`によりVMの全interfaceへ公開します。本番では認証、TLS、到達範囲の制限を別途設計します。

`depends_on`のhealth条件により、「containerプロセスが起動した」だけでなく「DBが接続を受け付けられる」状態を待たせます。Composeのservice依存とhealthcheckの関係は公式仕様に従っています。[7]

PostgreSQLをComposeで動かすのは、この教材を自己完結させるためです。本番環境でも必ずComposeでDBを運用すべき、という意味ではありません。本番では、バックアップ、可用性、更新、監視、障害復旧を含めた運用方式を別に選びます。

named volumeは、同じVM内でcontainerを作り直す間の保存領域です。`tofu destroy`ではVM diskごと削除されるため、DBデータも失われます。named volumeはbackupではないので、残す必要があるデータは`pg_dump`などで退避します。

### 5.3 手を動かす

この手順もDockerが導入済みのローカル環境で行う任意演習です。`POSTGRES_PASSWORD`と`DB_PASSWORD`の両方を同じローカルsecretへ置き換えてから実行してください。値が一致しないと`/db`は失敗します。`docker compose config --quiet`はこの一致を検証しません。

```bash
cd app
cp .env.example .env
# .envの2つのpasswordを同じローカルsecretへ置き換え、repositoryへcommitしない
docker compose config --quiet
docker compose up --detach --build
docker compose ps
docker compose logs --tail=50 api db
curl --fail http://127.0.0.1:8080/health
curl --fail http://127.0.0.1:8080/db
```

停止するときは、データを残すなら`down`だけを使います。

```bash
docker compose down
```

`docker compose down -v`はnamed volumeも削除するため、DBデータを捨てる実験以外では実行しません。

### ここまでで理解しておくこと

- `compose.yaml`はサービス間の関係をコード化する。
- APIからDBへの接続先はCompose service名である。
- `up`、`ps`、`logs`、`down`で実行状態を観察できる。

## 6. Ansible

### 6.1 Ansibleの役割

Ansibleは、管理対象へSSH接続し、moduleを実行して目的の状態へ近付けるagentlessな構成管理ツールです。Ansibleではinventory、playbook、task、module、variable、handlerなどを組み合わせます。[9][10][11]

```text
control node
     │ SSH
     ▼
managed VM
```

- **inventory**: 対象hostの一覧。
- **playbook**: 何を構成するかをYAMLで宣言した手順書。
- **task**: 一つの構成処理。
- **module**: package、copy、serviceなどを操作する部品。
- **variable**: hostや環境によって変える値。
- **handler**: 設定変更時だけ呼び出す通知先。
- **role**: playbookを再利用しやすくまとめる単位。
- **idempotence**: 同じplaybookを繰り返しても不要な変更がない性質。

この教材では初学者が処理の流れを追えるよう、最初からroleを細かく分割せず、`ansible/playbook.yml`一つにまとめています。roleという概念は理解しますが、構造を増やすこと自体を目的にしません。

### 6.2 Playbookが行うこと

`ansible/playbook.yml`は対象VMに対して、次を行います。

1. Docker公式APT repositoryを登録する。
2. Docker EngineとCompose pluginをpackageとして導入する。
3. `ubuntu`ユーザーを`docker` groupへ追加する。
4. `/opt/modern-infrastructure/app`へApplication sourceを配置する。
5. `.env`をrepository外で生成・配置する。
6. Docker serviceを有効化・起動する。
7. sourceや設定が変わったときだけ`docker compose up --build`をhandlerで実行する。

Dockerの導入先はhost VMです。trainingホストへDockerを導入することを統合手順の前提にはしません。Docker公式のUbuntu向け導入は公式APT repositoryを使う方法です。[4]

`ubuntu`を`docker` groupへ入れると、`sudo`なしでComposeを実行できます。ただしDocker daemonを通じてhostを操作できる強い権限でもあります。これは教材VMの学習者用設定であり、信頼できないユーザーが共用する本番hostへそのまま適用しません。

### 6.3 inline inventoryでIP転記をなくす

VMのIPを`inventory/hosts`へ手入力しません。OpenTofuのoutputをshell変数に読み込み、末尾にカンマを付けた一時inventoryとしてAnsibleへ渡します。

```bash
VM_IP="$(tofu -chdir=tofu output -raw vm_ip)"
ansible-playbook \
  -i "${VM_IP}," \
  -u ubuntu \
  ansible/playbook.yml
```

`"${VM_IP},"`のカンマは、Ansibleへ「これは1台のhostリストである」と知らせるために必要です。固定inventoryやdynamic inventory pluginを増やさなくても、今回の1台構成ならこの方法で十分です。

### 6.4 idempotenceを確かめる

同じコマンドを2回実行します。

```bash
ansible-playbook -i "${VM_IP}," -u ubuntu ansible/playbook.yml
ansible-playbook -i "${VM_IP}," -u ubuntu ansible/playbook.yml
```

2回目の最後のrecapで、対象hostの`changed=0`、`failed=0`、`unreachable=0`を確認します。`ok`が多いことではなく、「既に目的の状態なので変更しなかった」ことが重要です。

### ここまでで理解しておくこと

- AnsibleはSSH越しにVMのOS・ミドルウェアを構成する。
- moduleとhandlerを使い、同じplaybookを安全に繰り返す。
- inventoryへVM IPを手入力せず、OpenTofu outputから渡せる。

## 7. KVM / libvirtの最低限

### 7.1 三つの層

KVMはLinux kernelが提供するハードウェア仮想化機能、QEMUはVMを実行するプログラム、libvirtはVMを管理するAPI・管理レイヤーです。Linux kernelのKVM資料とlibvirtのQEMU driver資料は、この役割分担を前提にしています。[2][19][23]

```text
Linux kernel
    └─ KVM: CPU仮想化支援
         └─ QEMU: VMプロセスを実行
              └─ libvirt: domain / network / storageを管理
```

まず次を確認します。

```bash
test -e /dev/kvm
stat -c '%A %U:%G %n' /dev/kvm
virsh -c qemu:///system version
virsh -c qemu:///system net-list --all
virsh -c qemu:///system pool-list --all
```

`/dev/kvm`がない場合、VMのCPUをKVMで高速実行できません。`virsh`はlibvirtへ接続するCLIです。`qemu:///system`はsystem libvirt daemonへ接続するURIです。

### 7.2 network、storage、domain

- **network**: VMの仮想NICが接続するネットワーク。ここではlibvirtの既存`default` NAT networkを使う。
- **storage pool**: volumeを管理するlibvirtの保存場所。
- **volume**: VMのディスクやcloud-init ISO。
- **domain**: CPU、メモリ、ディスク、NICなどをまとめたVM定義。

domain、network、storageはlibvirtのXML概念で表されます。[20][21][22]

今回はbridge networkを追加せず、default NAT networkでtrainingホストからゲストへ接続します。[1]

Ubuntuのlibvirt手順でdefault storage poolが存在しない環境では、必要なディレクトリ型poolだけを用意します。これはtrainingホスト自身をOpenTofu管理対象にする処理ではありません。

```bash
sudo install -d -m 0755 /var/lib/libvirt/images
virsh -c qemu:///system pool-info default >/dev/null 2>&1 \
  || sudo virsh pool-define-as default dir --target /var/lib/libvirt/images
sudo virsh pool-start default 2>/dev/null || true
sudo virsh pool-autostart default
virsh -c qemu:///system pool-info default
```

`virsh list --all`、`virsh dominfo NAME`、`virsh console NAME`などでVMを調べられます。今回の通常接続はconsoleではなくSSHです。

### ここまでで理解しておくこと

- KVM、QEMU、libvirtは同じものではない。
- network、storage pool、volume、domainをlibvirtが管理する。
- 既存のNAT networkを使い、bridgeを増やさない。

## 8. OpenTofu

### 8.1 Terraformとの関係

OpenTofuはTerraformの設定記法・操作感と互換性を重視するオープンソースのInfrastructure as Code toolです。既存Terraform資産からの移行では、providerの対応状況やstateの扱いを確認します。[18] 本教材では混乱を避けるため、CLIは常に`tofu`と書きます。

### 8.2 HCLの基本語彙

OpenTofuの設定は主にHCL（HashiCorp Configuration Language）で書きます。

```text
provider  外部システムを操作する接続プラグイン
resource  作成・更新・削除する対象
 data     既存の状態を読み取る問い合わせ
variable  実行時に変えられる入力
output    実行後に表示・受け渡す値
state     設定と実際のInfrastructureを対応付ける状態情報
```

Providerは、libvirtのような外部システムのAPIをOpenTofuから使えるようにします。[13] Resourceは作成・更新・削除の対象を宣言します。[14] Data sourceは、例えば起動済みVMのDHCP leaseを読み取るように、既存情報を読むために使います。[15]

この教材では、`libvirt_volume`、`libvirt_cloudinit_disk`、`libvirt_domain`がresourceです。`libvirt_domain_interface_addresses`がVMのIPアドレスを読み取るdata sourceです。domainのNICがnetworkへ依存し、domainがvolumeへ依存するため、参照関係から実行順序が決まります。

### 8.3 stateは履歴ではない

stateは、OpenTofuが設定と実際のInfrastructureを対応付けるための状態情報です。Gitのcommitが「過去のコード」を保存するのに対し、stateは「現在どのresourceをどの実体として管理しているか」を追跡します。[16]

```text
HCL configuration ─┐
                   ├─ OpenTofu state ── 実際のlibvirt resource
libvirt API --------┘
```

stateには接続情報、resource属性、cloud-init user-dataなど、環境によっては機密情報が含まれる可能性があります。[17] そのため`*.tfstate`と`*.tfstate.*`をGitへ追加しません。stateを共有する必要があるチームでは、アクセス制御・暗号化・ロックを備えたbackendを別途設計します。

Git archiveに含まれるのは設定とコードであり、既存Infrastructureのstateではありません。既存VMの更新・destroyには、そのVMを管理しているstateが必要です。freshなarchive directoryで`apply`すると、新しいstateと新しい教材VMを作ります。

### 8.4 CLIの役割

```bash
tofu init       # providerを取得し、依存関係を初期化
tofu validate   # 設定の構造と型を検証
tofu plan       # 変更予定を表示
tofu apply      # planに従って作成・変更
tofu destroy    # stateで管理するresourceを削除
tofu output     # output値を表示
```

`tofu fmt`はHCLの書式をそろえます。`init`後に生成される`.terraform.lock.hcl`はproviderの選択を固定するため、Gitへ含めます。一方、`.terraform/`はキャッシュなので含めません。lock fileが固定するのはproviderであり、cloud image、APT package、pipxのAnsible、Docker package、container image tagまで固定するものではありません。したがって、この教材は外部artifactが取得できる範囲での再構築を扱い、完全なbit単位の再現性は主張しません。

### ここまでで理解しておくこと

- HCLのresourceは作りたいInfrastructure、data sourceは読み取りたい既存情報。
- outputがOpenTofuとAnsibleの境界になる。
- stateはGit履歴ではなく、設定と実体を対応付ける機密になり得る情報。

## 9. OpenTofu + libvirt

### 9.1 このrepositoryの構成

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

`versions.tf`ではOpenTofuの最低バージョンを`>= 1.10.0`、libvirt providerを`dmacvicar/libvirt` `0.9.9`に固定します。

Providerのdomain、volumeのschemaはOpenTofu本体ではなくprovider固有です。[28][29][30]

cloud-init diskとnetworkのschemaもprovider固有です。[31][32]

### 9.2 VMの作り方

`main.tf`が管理するのは次だけです。

- Ubuntu Server cloud imageを取り込む25 GiB VM disk。
- cloud-init user-dataを入れたISO。
- 2 vCPU、4 GiB RAMのlibvirt domain。
- 既存の`default` NAT networkへ接続するNIC。
- DHCP leaseを読むdata source。

Ubuntu cloud imageを25 GiBのVM diskとして使うため、`terraform_data`でdisk容量を整え、起動後にcloud-initでguestのroot filesystemを拡張します。いずれもVMを用意するInfrastructure側の処理です。

resource間のdependency（依存関係）は、参照や`depends_on`で表します。この構成では、disk resizeが終わってからdomainを作成する順序を明示しています。

cloud-initは、初回起動時にuser、authorized key、sudo設定などを適用する仕組みです。[24] `cloud-init.yaml`では、次を設定します。

- user `ubuntu`を作る。
- 実行時に渡したSSH公開鍵を`authorized_keys`へ入れる。
- password SSH loginとroot loginを無効化する。
- `sudo`をNOPASSWDで使えるようにする。

秘密鍵をcloud-initへ渡してはいけません。OpenTofuへ渡すのは公開鍵だけです。

### 9.3 実機での注意点

今回のUbuntu 26.04.1、libvirt 12.0.0、provider 0.9.9の組み合わせでは、domainのdisk sourceに`volume`を使うとAppArmorがQEMUのdisk accessを拒否する事象を確認しました。これは通常のlibvirt利用で必須の設定ではなく、他のversion・環境へ一般化できるとは限りません。

この教材では、libvirt volumeを管理しながらdomain側ではproviderの`source.file`で実体pathを参照します。同じ環境の使い捨てVMで`sec_label`を指定せずに起動でき、domain XMLにもdynamic AppArmor labelが残ることを確認しました。したがって、security labelingを弱める`sec_label = [{ type = "none" }]`は最終コードへ追加しません。

実環境ではlibvirt/AppArmorのversionとdisk pathの許可を確認し、必要なsecurity labelingを維持してください。`type = "none"`を通常の解決策としてproduction VMへコピーしてはいけません。

### ここまでで理解しておくこと

- OpenTofu providerがlibvirt APIを呼び、volume・cloud-init disk・domainを作ること。
- `terraform_data`はdisk拡張というInfrastructure操作だけを補助し、OS設定を担当しないこと。
- `dependency`と`depends_on`によって、disk拡張後にdomainを起動すること。
- VM IPはstateへ手入力せず、outputとAnsibleのinline inventoryへ渡すこと。

## 10. 統合ハンズオン

以下は確定した実行手順です。コマンドはtrainingホストで実行します。

### Phase 1: 前提条件を確認する

```bash
ssh -A training
. /etc/os-release
printf '%s %s\n' "$NAME" "$VERSION_ID"
nproc
free -h
df -h /
test -e /dev/kvm
virsh -c qemu:///system version
sudo -n true
```

trainingホストは教材上「KVMが利用可能なLinux学習用ホスト」として扱います。training自身をOpenTofuのresourceにはしません。

### Phase 2: 必要なpackageとCLIを導入する

trainingホストでは、教材に必要なpackageだけを追加します。前提セットアップでは、既存のdefault network/poolを確認し、必要な場合だけ起動・autostartまたは保存先directory・poolの準備を行います。

```bash
sudo apt update
sudo apt install -y \
  ca-certificates curl gnupg git openssh-client \
  qemu-system-x86 qemu-utils \
  libvirt-daemon-system libvirt-clients libvirt-daemon-config-network \
  cpu-checker pipx
```

trainingユーザーがlibvirtを操作できるようにgroupへ追加します。

```bash
sudo usermod -aG libvirt,kvm "$USER"
```

groupの変更を反映するため、いったん`exit`してから`ssh -A training`で再接続します。以降のPhaseは再接続後のsessionで実行してください。

Dockerはtrainingホストではなく、後でAnsibleから教材VMへ導入します。Docker Engineの公式APT repository手順をPlaybookへ実装しています。[4]

#### OpenTofu公式APT repository

OpenTofu公式のDebian/Ubuntu向けrepository手順に従います。[12]

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://get.opentofu.org/opentofu.gpg \
  | sudo tee /etc/apt/keyrings/opentofu.gpg >/dev/null
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey \
  | sudo gpg --no-tty --batch --dearmor \
      -o /etc/apt/keyrings/opentofu-repo.gpg
sudo chmod a+r /etc/apt/keyrings/opentofu.gpg \
  /etc/apt/keyrings/opentofu-repo.gpg
printf '%s\n' \
  'deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main' \
  | sudo tee /etc/apt/sources.list.d/opentofu.list >/dev/null
sudo chmod a+r /etc/apt/sources.list.d/opentofu.list
sudo apt update
sudo apt install -y tofu
```

#### Ansible

Ansible公式docsにあるpipx方式で、trainingユーザーの環境へ導入します。[9]

```bash
pipx ensurepath
export PATH="$HOME/.local/bin:$PATH"
pipx install --include-deps ansible
ansible --version
```

既に同じpackageが入っている場合、`pipx install`のエラー内容を確認し、再インストールではなく既存のversionを使います。

### Phase 3: libvirtのnetworkとstorageを確認する

```bash
sudo virsh net-start default 2>/dev/null || true
sudo virsh net-autostart default
virsh -c qemu:///system net-info default
virsh -c qemu:///system pool-info default
virsh -c qemu:///system list --all
```

`default` networkはNAT用途です。`default` poolがない場合だけ、次を実行します。

```bash
sudo install -d -m 0755 /var/lib/libvirt/images
virsh -c qemu:///system pool-info default >/dev/null 2>&1 \
  || sudo virsh pool-define-as default dir --target /var/lib/libvirt/images
sudo virsh pool-start default 2>/dev/null || true
sudo virsh pool-autostart default
```

既存のtraining host networkをbridgeへ変更したり、firewallを変更したりしません。

### Phase 4: OpenTofuを初期化してVMを作る

repositoryのルートで、SSH agentから公開鍵を読み込みます。

```bash
cd ~/modern-infrastructure
export PATH="$HOME/.local/bin:$PATH"
export TF_VAR_ssh_public_key="$(ssh-add -L | awk 'NR == 1 { print; exit }')"
export TF_VAR_libvirt_qemu_uid="$(id -u libvirt-qemu)"
export TF_VAR_libvirt_qemu_gid="$(getent group kvm | cut -d: -f3)"
test -n "$TF_VAR_ssh_public_key"
test -n "$TF_VAR_libvirt_qemu_uid"
test -n "$TF_VAR_libvirt_qemu_gid"
```

UID/GIDはvolume permissionへ使います。公開鍵と同様、stateやshell環境へ残り得る値なので、コマンド出力を記録へ貼り付けません。

```bash
tofu -chdir=tofu fmt -recursive
tofu -chdir=tofu init -input=false
tofu -chdir=tofu validate
tofu -chdir=tofu plan -input=false
tofu -chdir=tofu apply -input=false -auto-approve
```

`plan`で表示された変更が教材VM、volume、cloud-init diskだけであることを確認してから、確認済みの計画に対して`-auto-approve`を使います。`-input=false`は確認プロンプトを表示しない指定なので、未確認の計画へ盲目的に付けません。

### Phase 5: outputからVMを特定し、SSHを確認する

```bash
VM_IP="$(tofu -chdir=tofu output -raw vm_ip)"
test -n "$VM_IP"
printf '%s\n' "$VM_IP"
ssh-keygen -R "$VM_IP" >/dev/null 2>&1 || true
ssh -o StrictHostKeyChecking=accept-new ubuntu@"$VM_IP" \
  'id; hostname; sudo -n true'
```

IPは設定ファイルへ転記しません。毎回`tofu output -raw vm_ip`から得ます。destroy後の再構築で同じIPへ別のhost keyが割り当てられる場合に備え、実験用の古いknown_hosts entryだけを`ssh-keygen -R`で除去します。

### Phase 6: AnsibleでOSとDockerを構成する

```bash
ansible-playbook \
  -i "${VM_IP}," \
  -u ubuntu \
  ansible/playbook.yml
```

初回はDocker repositoryの鍵、package、ユーザーgroup、allowlistしたApplication files、`.env`、Compose serviceが設定されます。Playbookが作る`.env`はrepository外のcontroller cacheから生成されます。controller cacheとVM内のPostgreSQL volumeは同じpasswordを前提にするため、VMを残したままcacheを削除しないでください。値を画面やGitへ出しません。

### Phase 7: ComposeでAPIとPostgreSQLを起動する

Ansibleが配置したVM内のApplication directoryへSSHで入り、Compose状態を確認します。

```bash
ssh ubuntu@"$VM_IP" \
  'cd /opt/modern-infrastructure/app && docker compose -p modern-infrastructure ps && docker compose -p modern-infrastructure config --quiet'
```

ComposeはAnsibleのhandlerから起動されます。手動で再起動する場合は、VM内で次を使います。

```bash
cd /opt/modern-infrastructure/app
docker compose -p modern-infrastructure up --detach --build
docker compose -p modern-infrastructure ps
docker compose -p modern-infrastructure logs --tail=50 api db
```

### Phase 8: trainingホストからAPIとDB接続を確認する

```bash
curl --fail --silent "http://${VM_IP}:8080/health"
printf '\n'
curl --fail --silent "http://${VM_IP}:8080/db"
printf '\n'
```

`/health`はAPIの応答、`/db`はAPIからPostgreSQLへ接続して`SELECT 1`が成功した応答です。これで「containerが起動した」だけでなく「APIからDBへ通信できた」ことを確認します。

### Phase 9: Ansibleを再実行して冪等性を確認する

```bash
ansible-playbook \
  -i "${VM_IP}," \
  -u ubuntu \
  ansible/playbook.yml
```

recapで次を確認します。

```text
changed=0  failed=0  unreachable=0
```

OS package、Docker service、配置済みファイルに不要な変更が発生していない状態です。

### Phase 10: OpenTofuに意図しない差分がないことを確認する

```bash
tofu -chdir=tofu plan -input=false
```

`No changes`を確認します。変更が出たら、applyする前にstate、libvirt domain、volume、cloud-init、変数を調べます。`-detailed-exitcode`を使う場合、終了値0は差分なし、2は差分あり、1はエラーです。

### ここまでで理解しておくこと

- OpenTofu outputがAnsible inline inventoryへつながる。
- AnsibleはVMの中を構成し、ComposeはApplicationを起動する。
- `/health`と`/db`、Ansibleの`changed=0`、OpenTofuの`No changes`が別々の検証点になる。

## 11. destroyと再構築

### 11.1 教材VMだけを削除する

停止・削除の順序は、OpenTofuが管理しているVMとvolumeを対象にします。

```bash
tofu -chdir=tofu destroy
```

計画を確認しながら実行する通常形です。自動承認する場合は、計画を確認した後だけ次を使います。

```bash
tofu -chdir=tofu destroy -input=false -auto-approve
```

削除後に確認します。

```bash
virsh -c qemu:///system list --all
virsh -c qemu:///system vol-list default
tofu -chdir=tofu state list
```

教材VM、教材用volume、cloud-init diskが消え、trainingホストのOpenTofu、Ansible、libvirt package、default network、default poolは残ります。training自身をdestroy対象へ入れないことが重要です。

### 11.2 Gitのコードから再構築する

まず作業treeを確認します。

```bash
git status --short
git diff --check
```

`.terraform.lock.hcl`を含むcommit済みのコードから、同じ前提条件（default network/pool、SSH agent、実行時変数、外部repositoryへ到達できる環境）の上で、次の順に新しいVMを再構築します。既存VMを更新・destroyする場合は、そのVMのstateがある作業directoryを使います。

```bash
export PATH="$HOME/.local/bin:$PATH"
export TF_VAR_ssh_public_key="$(ssh-add -L | awk 'NR == 1 { print; exit }')"
export TF_VAR_libvirt_qemu_uid="$(id -u libvirt-qemu)"
export TF_VAR_libvirt_qemu_gid="$(getent group kvm | cut -d: -f3)"
tofu -chdir=tofu init -input=false
tofu -chdir=tofu apply -input=false -auto-approve
VM_IP="$(tofu -chdir=tofu output -raw vm_ip)"
ansible-playbook -i "${VM_IP}," -u ubuntu ansible/playbook.yml
curl --fail --silent "http://${VM_IP}:8080/health"
printf '\n'
curl --fail --silent "http://${VM_IP}:8080/db"
printf '\n'
```

この手順にはIPの手入力、training自身の再作成、hostのfirewall・SSH・kernel変更がありません。生成されるstateと`.env`はGitの外に置かれます。

### ここまでで理解しておくこと

- `destroy`はOpenTofu stateで管理する教材VMだけに対して実行する。
- destroy後もGitのコード、provider lock、実行時変数から同じ層を再構築できる。
- 再構築できることがIaCの価値であり、最終成果物である。

## 12. クラウド・オンプレへの応用

今回libvirtを使う理由は、クラウド契約なしでIaCを実体験できるためです。OpenTofuの考え方は、次のようにproviderを変えて応用できます。

```text
OpenTofu
 ├─ libvirt
 ├─ AWS
 ├─ Google Cloud
 ├─ Azure
 ├─ VMware
 └─ その他Provider
```

ただし、resourceの名前、必須属性、networkやstorageのモデルはprovider固有です。「OpenTofuを使えばInfrastructure定義まで完全にcloud非依存になる」とは考えません。共通化されるのは主に、`init`、`plan`、`apply`、`destroy`、state、変数、outputという操作体系です。

libvirtでは`libvirt_domain`、AWSではEC2など、似た目的でもresource schemaは別です。Providerを変えると、設計、権限、network、state backend、運用手順を再検証します。

### ベンダーロックイン

- DockerはApplicationをimageと設定の境界へまとめ、移植性を高めやすい。
- OpenTofuはIaCの操作体系を共通化する。
- Provider resourceはクラウドや仮想化基盤の固有仕様を持つ。
- PostgreSQLのような標準技術は、データ形式や接続方法の選択肢を保ちやすく、Data lock-inを抑えやすい。
- ロックインを完全にゼロにすることは目的ではない。
- 「APIの境界」「DB接続の境界」「Application imageの境界」のように、交換可能な境界を意識して設計する。

### ここまでで理解しておくこと

- providerを変えても、resource schemaまで同じになるわけではない。
- 移植性と運用コストのバランスを取る。
- lock-inを消すのではなく、交換可能な境界を設計する。

## 13. 次に学ぶもの

この教材の次に、必要になった順で次を学びます。

- **CI/CD**: commitをきっかけにvalidate、plan、test、deployを自動化する。
- **Role設計**: AnsibleのPlaybookを複数環境・複数teamで再利用する。
- **Secrets管理**: `.env`を直接配布せず、権限、ローテーション、監査を設計する。
- **Kubernetes / Helm**: containerを多数のnodeへスケールさせる別の運用モデル。Dockerと同時に必須ではない。
- **Packer**: VM imageを事前作成する仕組み。
- **GitOps**: Gitの変更をclusterやInfrastructureへ同期する運用。
- **Vault等**: secretの保管と払い出しを専門に扱う仕組み。

Kubernetesを理解するためにも、まずは今回のように「VMの中でcontainerを起動し、network、volume、healthを観察する」経験が役立ちます。全てを同時に導入せず、現在のボトルネックに対応する道具から学びます。

### ここまでで理解しておくこと

- 次の道具は、今回の責務分離を理解した後に追加する。
- KubernetesはDockerの基礎と同時に必須ではない。
- 自動化の範囲を広げる前に、state、secret、復旧手順を設計する。

## 付録: 完了チェックリスト

- [ ] trainingの前提条件を確認した。
- [ ] 必要package、OpenTofu、Ansibleを導入した。
- [ ] `/dev/kvm`、libvirt network、storage poolを確認した。
- [ ] `tofu init`、`validate`、`plan`、`apply`が成功した。
- [ ] `tofu output -raw vm_ip`からIPを取得した。
- [ ] IPをinventoryへ手入力せずAnsibleを実行した。
- [ ] `docker compose -p modern-infrastructure ps`で`api`と`db`を確認した。
- [ ] trainingから`/health`へアクセスした。
- [ ] `/db`でAPIからPostgreSQLへの接続を確認した。
- [ ] Ansible 2回目が`changed=0`だった。
- [ ] OpenTofu planが`No changes`だった。
- [ ] `tofu destroy`で教材VMだけを削除した。
- [ ] Gitのcommit済みコードから再構築した。
- [ ] `.terraform/`、tfstate、`.env`、秘密情報がGit対象外だった。

## Sources

[1] https://ubuntu.com/server/docs/how-to/virtualisation/libvirt
[2] https://ubuntu.com/server/docs/how-to/virtualisation/qemu
[3] https://documentation.ubuntu.com/release-notes/26.04
[4] https://docs.docker.com/engine/install/ubuntu
[5] https://docs.docker.com/compose/install/linux
[6] https://docs.docker.com/reference/compose-file
[7] https://docs.docker.com/reference/compose-file/services
[8] https://docs.docker.com/reference/compose-file/volumes
[9] https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html
[10] https://docs.ansible.com/ansible/latest/getting_started/basic_concepts.html
[11] https://docs.ansible.com/ansible/latest/getting_started/get_started_ansible.html
[12] https://opentofu.org/docs/intro/install/deb
[13] https://opentofu.org/docs/language/providers
[14] https://opentofu.org/docs/language/resources/syntax
[15] https://opentofu.org/docs/language/data-sources
[16] https://opentofu.org/docs/language/state/purpose
[17] https://opentofu.org/docs/language/state/sensitive-data
[18] https://opentofu.org/docs/intro/migration
[19] https://libvirt.org/drvqemu.html
[20] https://libvirt.org/formatnetwork.html
[21] https://libvirt.org/formatstorage.html
[22] https://libvirt.org/formatdomain.html
[23] https://docs.kernel.org/virt/kvm
[24] https://cloudinit.readthedocs.io/en/latest
[25] https://git-scm.com/docs/gitglossary
[26] https://git-scm.com/docs/gitignore
[27] https://git-scm.com/docs/git-diff
[28] https://github.com/dmacvicar/terraform-provider-libvirt/tree/v0.9.9
[29] https://raw.githubusercontent.com/dmacvicar/terraform-provider-libvirt/v0.9.9/docs/resources/domain.md
[30] https://raw.githubusercontent.com/dmacvicar/terraform-provider-libvirt/v0.9.9/docs/resources/volume.md
[31] https://raw.githubusercontent.com/dmacvicar/terraform-provider-libvirt/v0.9.9/docs/resources/cloudinit_disk.md
[32] https://raw.githubusercontent.com/dmacvicar/terraform-provider-libvirt/v0.9.9/docs/resources/network.md
