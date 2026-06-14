#!/bin/sh
# provision.sh — owlv ベアメタルリストア完全自動化
#
# ━━━ 【事前準備】OpenBSD 手動インストール直後にやること ━━━━━━━━━━━━━━━━
#
# OpenBSD はデフォルトで root の SSH ログインを禁止している。
# provision.sh を送り込む前に、物理コンソール (またはインストール時) で
# 管理者アカウントを作成しておく必要がある。
#
# 1. root になる (OpenBSD はデフォルトで root SSH 不可。インストール時に設定した
#    root パスワードで su する):
#      su -
#
# 2. インストール時に作ったユーザーを wheel に追加する
#    (すでに存在するユーザーを管理者にする場合):
#      usermod -G wheel <YOUR_USERNAME>
#
#    または新規に管理者ユーザーを作る場合:
#      useradd -m -G wheel -s /bin/ksh <YOUR_USERNAME>
#      passwd <YOUR_USERNAME>
#
# 3. doas を有効化:
#      echo 'permit persist :wheel' > /etc/doas.conf
#
# 4. SSH 公開鍵の登録 (ホスト側で root として実行):
#
#    【各開発機で鍵を生成する (鍵がまだない場合)】
#    開発機 (手元の Mac / PC) それぞれで以下を実行。パスフレーズは必ず設定すること。
#    -C のコメントは「この鍵を作った開発機の名前＠接続先 IP」にすると後で判別しやすい。
#      ssh-keygen -t ed25519 -C "<この開発機の名前>@192.168.50.200"
#      # 例: ssh-keygen -t ed25519 -C "macbook-alice@192.168.50.200"
#      # 例: ssh-keygen -t ed25519 -C "thinkpad-bob@192.168.50.200"
#    生成された ~/.ssh/id_ed25519.pub の内容を手元に控えておく。
#.     # 例： ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7QNOXZKGBsPmvCwj4AJInjG7cnb0aRh5wKGxThygPz ketchup@192.168.50.200
#
#    【ホスト側で authorized_keys に追加する (root として実行)】
#    登録したい全員分を 1 行 1 鍵で書く。あとから追加する場合は >> で追記。
#      install -d -m 700 /home/<YOUR_USERNAME>/.ssh
#      vi /home/<YOUR_USERNAME>/.ssh/authorized_keys
#        # ssh-ed25519 AAAA... macbook-alice@192.168.50.200
#        # ssh-ed25519 AAAA... thinkpad-bob@192.168.50.200
#        # ssh-ed25519 AAAA... macbook-alice-work@192.168.50.200  ← 同一人物の別マシンも可
#      chmod 600 /home/<YOUR_USERNAME>/.ssh/authorized_keys
#      chown -R <YOUR_USERNAME> /home/<YOUR_USERNAME>/.ssh
#
#    【接続確認 (各開発機から)】
#      ssh <YOUR_USERNAME>@192.168.50.200    # パスフレーズを入力してログインできれば OK
#
# ━━━ 【実行手順】開発機から ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# 5. 時刻を合わせる (OCSP 検証が通らなくなるため必須):
#      ssh <YOUR_USERNAME>@192.168.50.200 'doas rdate -n pool.ntp.org'
#
#    macOS Sequoia 以降は rsync が openrsync に置き換わっており、OpenBSD 側の
#    openrsync と --delete 系フラグの互換性がない。scp -r を使うこと。
#
#   # (1) 古い残骸をリモートから削除 (再実行時にネストするのを防ぐ)
#   ssh <YOUR_USERNAME>@192.168.50.200 'rm -rf /tmp/infra'
#
#   # (2) infra ディレクトリごと /tmp/ に転送 → /tmp/infra/ になる
#   scp -r infra <YOUR_USERNAME>@192.168.50.200:/tmp/
#
#   # (3) リモートで配置・プロビジョニング実行 (コマンドは '' で囲んでリモートで実行)
#   ssh <YOUR_USERNAME>@192.168.50.200 \
#       'doas install -d /etc/owl && doas mv /tmp/infra /etc/owl/infra && doas sh /etc/owl/infra/provision.sh'
#
# ━━━ 【Yubikey が届いたら】━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#   ssh <YOUR_USERNAME>@<HOST_IP> 'doas sh /etc/owl/infra/host/yubikey-setup.sh'
#
# この時点では SSH を維持する。
# Yubikey セットアップ完了まで管理者がロックアウトされないようにするため。

set -eu
trap '_on_exit $?' EXIT

# ── ヘルパー関数 ───────────────────────────────────────────
# 関数はログ設定より先に定義する (trap 発火時に未定義にならないよう)

_on_exit() {
    local rc=$1
    if [ "$rc" -ne 0 ]; then
        printf '[%s] エラー終了 (exit %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc"
        echo ""
        echo "エラー終了 (exit $rc)。PF ルールを安全な暫定状態に維持します。"
        echo "ログ: ${LOGFILE:-'(未設定)'}"
        echo "再実行: sh /etc/owl/infra/provision.sh"
    else
        printf '[%s] プロビジョニング正常終了\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    fi
}

_die()  { printf '[%s] FATAL: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }
_step() { printf '\n━━━ [%s/%s] %s\n' "$1" "$TOTAL" "$2"; }
_ok()   { printf '    ✓ %s\n' "$*"; }
_info() { printf '      %s\n' "$*"; }
_log()  { printf '    [%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

# ── ログファイル ───────────────────────────────────────────
# OpenBSD /bin/sh (pdksh 派生) はプロセス置換 >(cmd) 未サポート。
# named pipe + バックグラウンド tee で端末とファイルに同時出力する。
mkdir -p /var/log/owl
LOGFILE="/var/log/owl/provision-$(date +%Y%m%d-%H%M%S).log"
_LOGPIPE="/tmp/owl-prov-$$.pipe"
mkfifo -m 600 "$_LOGPIPE"
tee -a "$LOGFILE" < "$_LOGPIPE" &
exec > "$_LOGPIPE" 2>&1
rm -f "$_LOGPIPE"   # 名前を消してもプロセス間の fd は維持される
printf '[%s] ログ出力先: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LOGFILE"

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"
[ "$(uname)" = "OpenBSD" ] || _die "OpenBSD でのみ実行可能"

_log "OS: $(uname -srm)  カーネル: $(sysctl -n kern.version | head -1)"
_log "ホスト: $(hostname)"

SELF="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SELF}/owl-config.toml"
TOTAL=7

[ -f "$CONFIG" ] || _die "$CONFIG が見つかりません"

# ── TOML 読み込み ──────────────────────────────────────────
_toml() {
    awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k {
            sub(/^[^=]+=[ ]*/, "")  # "key = " を除去
            sub(/[ ]*#.*$/, "")     # インラインコメント "# ..." を除去
            gsub(/^"|"$/, "")       # 前後の引用符を除去
            print; exit
        }
    ' "$CONFIG"
}

OWL_RELEASE=$(_toml  "host"                "openbsd_release")
WAN_IF=$(_toml       "host"                "wan_interface")
OWL_AP_IP=$(_toml    "network.internal_lan" "ap_vm")
OWL_DB_IP=$(_toml    "network.internal_lan" "db_vm")
OWL_GIT_IP=$(_toml   "network.dev_lan"     "git_vm")
OWL_BUILD_IP=$(_toml "network.dev_lan"     "build_vm")
GHC_VERSION=$(_toml  "toolchain"           "ghc_version")
PG_VERSION=$(_toml   "app"                 "pg_version")
FORGEJO_VER=$(_toml  "forgejo"             "version")
OBD_MIRROR=$(_toml   "install"             "openbsd_mirror")

_log "設定読み込み完了:"
_log "  OWL_RELEASE=${OWL_RELEASE}  WAN_IF=${WAN_IF}"
_log "  internal_lan: AP=${OWL_AP_IP} DB=${OWL_DB_IP}"
_log "  dev_lan:      Git=${OWL_GIT_IP} Build=${OWL_BUILD_IP}"
_log "  GHC=${GHC_VERSION}  PG=${PG_VERSION}  Forgejo=${FORGEJO_VER}"
_log "  mirror=${OBD_MIRROR}"

HOST_INT_IP="10.0.1.1"
HOST_DEV_IP="10.0.2.1"
PROV_KEY=/etc/owl/prov_ed25519      # プロビジョニング用の使い捨て SSH 鍵
BACKUP_KEY=/etc/owl/backup_ed25519  # DR 用の恒久 SSH 鍵 (owl-control.sh が使用)
LOGDIR=/var/log/owl

export OWL_AP_IP OWL_DB_IP OWL_GIT_IP OWL_BUILD_IP \
       OWL_RELEASE GHC_VERSION PG_VERSION FORGEJO_VER

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " owlv プロビジョニング! (OpenBSD ${OWL_RELEASE})"
echo " AP:${OWL_AP_IP}  DB:${OWL_DB_IP}"
echo " Git:${OWL_GIT_IP}  Build:${OWL_BUILD_IP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── STEP 1: ホスト基盤 ────────────────────────────────────
_step 1 "ホスト基盤セットアップ"

install -d -m 750 /etc/owl
install -d -m 750 "$LOGDIR"

# 管理スクリプトを配置
install -m 700 "${SELF}/host/owl-control.sh"         /usr/local/sbin/owl-control.sh
install -m 700 "${SELF}/host/owl-integrity-check.sh" /usr/local/sbin/owl-integrity-check.sh
install -m 700 "${SELF}/host/owl-pfctl-pinhole"      /usr/local/sbin/owl-pfctl-pinhole

# known_hosts は provision が上書きできるよう初期化する
install -m 600 /dev/null /etc/owl/known_hosts
_ok "管理スクリプト配置"

# 設定ファイルを配置 (doas.conf / newsyslog.conf / crontab)
# vmd.conf は STEP 3 でディスクイメージ作成後に配置する (先に置くと起動失敗)
# pf.conf と rc.conf.local は STEP 7 の本番封鎖時に適用する
install -m 644 "${SELF}/host/doas.conf"      /etc/doas.conf
install -m 644 "${SELF}/host/newsyslog.conf" /etc/newsyslog.conf
install -m 600 "${SELF}/host/crontab"        /etc/crontab
_ok "設定ファイル配置"

# owl-control 専用ユーザー
id owl-control >/dev/null 2>&1 || useradd -s /sbin/nologin -d /nonexistent owl-control

# 必要パッケージ (この時点では外向き通信が開いているので pkg_add で取得)
pkg_add age rclone 2>/dev/null && _ok "age / rclone インストール" || \
    _info "警告: age / rclone の自動インストール失敗。後で手動実行: pkg_add age rclone"

# ── bridge 設定 ──────────────────────────────────────────────
# 再実行時は vmd がすでに bridge を保持しており SIOCAIFADDR が失敗する。
# vmd を先に停止してから bridge を設定し、後で再起動する。
_log "vmd の実行状態を確認..."
if pgrep -x vmd >/dev/null 2>&1; then
    _log "vmd が実行中 → bridge 再設定のため停止します"
    rcctl stop vmd 2>/dev/null || true
    sleep 1
    if pgrep -x vmd >/dev/null 2>&1; then
        _die "vmd を停止できませんでした。手動で 'rcctl stop vmd' を実行してください"
    fi
    _log "vmd 停止完了"
else
    _log "vmd は未起動"
fi

# OpenBSD 7.9 では bridge に直接 inet アドレスを付与できない (SIOCAIFADDR: ENOTTY)。
# vmd(8) man page の正規パターン:
#   vether = ホストの IP を持つ仮想 Ethernet インターフェース
#   bridge = VM virtual NIC と vether を束ねる L2 スイッチ (IP なし)
# VM → bridge → vether(IP) の経路でホストと通信する。

# ── internal_lan: vether0 (IP) + bridge0 (スイッチ) ──────
_log "vether0 を destroy → create..."
ifconfig vether0 destroy 2>/dev/null && _log "vether0 destroy 完了" || _log "vether0 は存在しなかった"
ifconfig vether0 create
_log "vether0 に inet ${HOST_INT_IP} netmask 255.255.255.0 up を設定..."
ifconfig vether0 inet "${HOST_INT_IP}" netmask 255.255.255.0 up \
    || _die "vether0 への IP 設定失敗"
_log "vether0 状態: $(ifconfig vether0 | grep 'inet ')"

_log "bridge0 を destroy → create → vether0 を追加..."
ifconfig bridge0 destroy 2>/dev/null && _log "bridge0 destroy 完了" || _log "bridge0 は存在しなかった"
ifconfig bridge0 create
ifconfig bridge0 add vether0
ifconfig bridge0 up
_log "bridge0 members: $(ifconfig bridge0 | grep 'member:' || echo '(なし)')"

# ── dev_lan: vether1 (IP) + bridge1 (スイッチ) ──────────
_log "vether1 を destroy → create..."
ifconfig vether1 destroy 2>/dev/null && _log "vether1 destroy 完了" || _log "vether1 は存在しなかった"
ifconfig vether1 create
_log "vether1 に inet ${HOST_DEV_IP} netmask 255.255.255.0 up を設定..."
ifconfig vether1 inet "${HOST_DEV_IP}" netmask 255.255.255.0 up \
    || _die "vether1 への IP 設定失敗"
_log "vether1 状態: $(ifconfig vether1 | grep 'inet ')"

_log "bridge1 を destroy → create → vether1 を追加..."
ifconfig bridge1 destroy 2>/dev/null && _log "bridge1 destroy 完了" || _log "bridge1 は存在しなかった"
ifconfig bridge1 create
ifconfig bridge1 add vether1
ifconfig bridge1 up
_log "bridge1 members: $(ifconfig bridge1 | grep 'member:' || echo '(なし)')"

# 再起動時も自動設定されるよう hostname.* を書いておく (パーミッション 640 必須)
_log "hostname.vether0/bridge0/vether1/bridge1 を書き込み..."
printf 'inet %s 255.255.255.0\nup\n' "${HOST_INT_IP}" > /etc/hostname.vether0
chmod 640 /etc/hostname.vether0
printf 'add vether0\nup\n' > /etc/hostname.bridge0
chmod 640 /etc/hostname.bridge0
printf 'inet %s 255.255.255.0\nup\n' "${HOST_DEV_IP}" > /etc/hostname.vether1
chmod 640 /etc/hostname.vether1
printf 'add vether1\nup\n' > /etc/hostname.bridge1
chmod 640 /etc/hostname.bridge1

_ok "vether0+bridge0 (${HOST_INT_IP}) / vether1+bridge1 (${HOST_DEV_IP}) 設定"

# vmd をスイッチのみの最小 config で起動する
# ディスクイメージ参照を含む完全な vm.conf は STEP 3 で配置する
_log "最小 vm.conf (スイッチ定義のみ) を書き込み..."
cat > /etc/vm.conf <<'VMDEOF'
switch "internal_lan" {
    interface bridge0
}
switch "dev_lan" {
    interface bridge1
}
VMDEOF

_log "vmd を enable + start..."
rcctl enable vmd
if ! rcctl start vmd 2>/dev/null; then
    _log "vmd 起動失敗 — /var/log/messages の直近ログ:"
    grep -i vmd /var/log/messages | tail -10 | while read -r l; do _log "  $l"; done
    _die "vmd の起動に失敗しました"
fi
sleep 1
_log "vmd PID: $(pgrep -x vmd || echo '不明')"
_log "vmctl status:"
vmctl status 2>/dev/null | while read -r l; do _log "  $l"; done
_ok "vmd 起動 (スイッチのみ)"

# ── STEP 2: 仮想ネットワーク ──────────────────────────────
_step 2 "仮想ネットワーク設定"

# VM がミラーからインストールセットを取得できるよう IP フォワーディング + NAT を有効化
# (本番封鎖は STEP 7 で適用するため、ここでは最小限のルールのみ)
_log "IP フォワーディングを有効化..."
sysctl net.inet.ip.forwarding=1
_log "暫定 PF ルールを適用 (NAT: VM → WAN)..."
# 注意: `cat | pfctl -f - <<PFEOF` は NG。
#   ヒアドキュメントは右辺 (pfctl) に渡るが left の cat は端末 stdin を待ちフリーズする。
#   正しくは pfctl に直接ヒアドキュメントを渡す。
pfctl -f - <<PFEOF
# プロビジョニング中の暫定 PF ルール
# NAT: VM → インターネット (OpenBSD ミラーからインストールセットを取得)
match out on ${WAN_IF} from { 10.0.1.0/24, 10.0.2.0/24 } nat-to (${WAN_IF})

set block-policy drop
set skip on lo0
block all

# keep state を明示する。
# flags S/SA のみでは stateful tracking が確立されず、戻りパケットが落ちる。

# SSH: 管理アクセスを維持 (Yubikey セットアップ完了まで維持する §yubikey-setup.sh)
pass in on ${WAN_IF} proto tcp to port 22 keep state

# VM ↔ ホスト: DHCP / HTTP (autoinstall) + SSH (プロビジョニング)
# bridge0/1 = 手動生成スイッチ, veb0/1 = vmd 自動生成スイッチ (両方許可)
# vether0/1 = ホスト IP (VM-ホスト通信)
pass on bridge0 all keep state
pass on bridge1 all keep state
pass on veb0    all keep state
pass on veb1    all keep state
pass on vether0 all keep state
pass on vether1 all keep state

# VM → インターネット: インストールセット取得のみ
pass out on ${WAN_IF} all keep state
PFEOF
_log "pfctl -s rules:"
pfctl -s rules 2>/dev/null | while read -r l; do _log "  $l"; done
_ok "暫定 PF (NAT) 適用"

# ── STEP 3: VM ディスクイメージ作成 ──────────────────────
_step 3 "VM ディスクイメージ作成"
_log "ディスクイメージディレクトリ: /var/vmm"
install -d /var/vmm
for spec in "ap:20G" "db:50G" "git:50G" "build:50G"; do
    name="${spec%%:*}"; size="${spec##*:}"; img="/var/vmm/${name}.img"
    if [ ! -f "$img" ]; then
        _log "${name}.img (${size}) を作成中..."
        vmctl create -s "$size" "$img" && _ok "${name}.img (${size}) 作成"
    else
        _log "${name}.img 既存 ($(du -h "$img" | cut -f1)) → スキップ"
        _info "${name}.img 既存のためスキップ"
    fi
done

_log "完全な vm.conf を配置..."
install -m 600 "${SELF}/host/vmd.conf" /etc/vm.conf
_log "vmctl reload..."
if vmctl reload 2>/dev/null; then
    _log "vmctl reload 成功"
else
    _log "vmctl reload 失敗 → rcctl restart vmd にフォールバック"
    rcctl restart vmd
fi
_ok "vm.conf (VM 定義込み) を配置・reload"

# ── STEP 4: SSH 鍵生成 ────────────────────────────────────
_step 4 "SSH 鍵生成"

# プロビジョニング用の使い捨て鍵 (STEP 7 で削除)
_log "プロビジョニング鍵を生成: ${PROV_KEY}"
ssh-keygen -t ed25519 -N "" -C "owl-prov-$(date +%Y%m%d)" -f "$PROV_KEY" -q
chmod 600 "$PROV_KEY"
PROV_PUBKEY="$(cat ${PROV_KEY}.pub)"
_log "プロビジョニング公開鍵: ${PROV_PUBKEY}"
_ok "プロビジョニング鍵: ${PROV_KEY}"

# DR バックアップ用の恒久鍵 (owl-control.sh が VM に SSH するために使用)
if [ ! -f "$BACKUP_KEY" ]; then
    _log "DR バックアップ鍵を新規生成: ${BACKUP_KEY}"
    ssh-keygen -t ed25519 -N "" -C "owl-backup" -f "$BACKUP_KEY" -q
    chmod 600 "$BACKUP_KEY"
    _ok "DR バックアップ鍵: ${BACKUP_KEY} (各 VM の authorized_keys に追加される)"
else
    _log "DR バックアップ鍵: ${BACKUP_KEY} 既存 → 再利用"
    _info "DR バックアップ鍵: ${BACKUP_KEY} 既存のため再利用"
fi
BACKUP_PUBKEY="$(cat ${BACKUP_KEY}.pub)"
_log "バックアップ公開鍵: ${BACKUP_PUBKEY}"

# autoinstall サーバー (dhcpd + httpd)
cat > /tmp/dhcpd-prov.conf <<DHCP
option domain-name-servers ${HOST_INT_IP};
subnet 10.0.1.0 netmask 255.255.255.0 {
    range 10.0.1.200 10.0.1.210;
    option routers ${HOST_INT_IP};
    next-server ${HOST_INT_IP};
}
subnet 10.0.2.0 netmask 255.255.255.0 {
    range 10.0.2.200 10.0.2.210;
    option routers ${HOST_DEV_IP};
    next-server ${HOST_DEV_IP};
}
DHCP
# dhcpd は IP を持つ vether 上で listen する (bridge は L2 スイッチのみで IP なし)
# rcctl restart は "enabled" なサービスにしか使えない。
# STEP 7 で disable されている再実行時のために enable → stop(安全) → start の順にする。
_log "dhcpd を enable → flags 設定 → 起動..."
rcctl enable dhcpd
rcctl set dhcpd flags "-c /tmp/dhcpd-prov.conf vether0 vether1"
rcctl stop dhcpd 2>/dev/null || true   # 再実行時の既存インスタンスを停止
rcctl start dhcpd
_log "dhcpd PID: $(pgrep -x dhcpd || echo '不明')"

install -d /tmp/owl-install-www
cat > /tmp/httpd-prov.conf <<HTTP
server "prov" {
    listen on ${HOST_INT_IP} port 80
    listen on ${HOST_DEV_IP} port 80
    root "/tmp/owl-install-www"
    directory auto index
}
HTTP
_log "httpd を enable → flags 設定 → 起動..."
rcctl enable httpd
rcctl set httpd flags "-f /tmp/httpd-prov.conf"
rcctl stop httpd 2>/dev/null || true   # 再実行時の既存インスタンスを停止
rcctl start httpd
_log "httpd PID: $(pgrep -x httpd || echo '不明')"
_ok "DHCP / HTTP サーバー起動"

# ── STEP 5: VM OS インストール (autoinstall) ─────────────
_step 5 "VM OS autoinstall"
_log "ホストメモリ: 物理=$(sysctl -n hw.physmem | awk '{printf "%d MB", $1/1024/1024}') 空き=$(sysctl -n hw.usermem | awk '{printf "%d MB", $1/1024/1024}')"
_log "VMM 状態:"
dmesg | grep -i 'vmm\|vmx\|svm\|ept\|rvi' | while read -r l; do _log "  dmesg: $l"; done
vmctl status 2>/dev/null | while read -r l; do _log "  vmctl: $l"; done
# vmm(4) が利用可能か確認する (VT-x/AMD-V が BIOS で無効だと vmm0 がアタッチされない)
if ! dmesg | grep -q 'vmm0 at mainbus0'; then
    _die "vmm(4) ドライバーが見つかりません。\n  原因: CPU が仮想化非対応、または BIOS で Intel VT-x / AMD-V が無効です。\n  対処: BIOS/UEFI で VT-x (Intel) または SVM (AMD) を有効にして再起動してください。"
fi
_info "install.conf を自動生成し、1 台ずつ順番にインストールします。"
_info "インストールセットは ${OBD_MIRROR} から取得します。"
_info "インストーラー起動メモリ: 512M (-m オプション; vm.conf の本番値とは別)"

_vm_install() {
    local vmname="$1" vmip="$2" gateway="$3" disk="$4" swname="$5"

    _info "-- ${vmname} (${vmip})"
    _log "[${vmname}] install.conf を生成 (gateway=${gateway})..."

    # install.conf を動的生成して httpd のルートに置く
    # VM の installer が http://<gateway>/install.conf を取得する
    cat > /tmp/owl-install-www/install.conf <<EOF
System hostname = ${vmname}
Password for root = *
Network interfaces = vio0
IPv4 address for vio0 = ${vmip}
Netmask for vio0 = 255.255.255.0
Default IPv4 route = ${gateway}
DNS domain name = local
DNS nameservers = ${gateway}
Do you expect to run the X Window System = no
Do you want the X Window System to be started by xdm = no
Setup a user = no
Allow root ssh login = prohibit-password
Public ssh key for root account = ${PROV_PUBKEY}
What timezone are you in = Asia/Tokyo
Which disk is the root disk = sd0
Use (W)hole disk MBR, whole disk (G)PT or (E)dit? = gpt
Set name(s) = -x* -game* -man* done
Location of sets = http
HTTP Server = ${OBD_MIRROR}
Server directory = pub/OpenBSD/${OWL_RELEASE}/amd64
EOF

    # bsd.rd で起動
    # -m 512M: インストーラーは 512M で十分動く。vm.conf の本番メモリ (最大 4G) を
    #          確保しようとすると ENOMEM になる環境でも完走できる。
    #          インストール完了後に通常起動すれば vm.conf の値が使われる。
    local bsdrd="/var/vmm/bsd.rd-${OWL_RELEASE}"
    local inst_mem="512M"
    if [ ! -f "$bsdrd" ]; then
        _log "[${vmname}] bsd.rd-${OWL_RELEASE} を取得中..."
        _info "    bsd.rd を取得中..."
        ftp -o "$bsdrd" \
            "https://${OBD_MIRROR}/pub/OpenBSD/${OWL_RELEASE}/amd64/bsd.rd" \
            || _die "bsd.rd の取得に失敗しました"
        _log "[${vmname}] bsd.rd 取得完了: $(du -h "$bsdrd" | cut -f1)"
    else
        _log "[${vmname}] bsd.rd-${OWL_RELEASE} 既存 → 再利用"
    fi

    # running/starting の場合のみ停止する。
    # stopped エントリは呼び出し前の vmctl reset vms で除去済み。
    # stopped のまま vmctl start -b を呼ぶと EALREADY になるため。
    _log "[${vmname}] 既存 VM 状態を確認..."
    _vmstate=$(vmctl status 2>/dev/null | awk -v n="$vmname" '$NF==n{print $(NF-1)}')
    _log "[${vmname}] 現在状態: ${_vmstate:-なし}"
    if [ "$_vmstate" = "running" ] || [ "$_vmstate" = "starting" ]; then
        _log "[${vmname}] 実行中 → vmctl stop -f (3 秒待機)..."
        vmctl stop -f "$vmname" 2>/dev/null || true
        sleep 3
        _log "[${vmname}] 停止後の状態: $(vmctl status 2>/dev/null | awk -v n="$vmname" '$NF==n{print $(NF-1)}')"
    fi

    _log "利用可能メモリ: $(sysctl -n hw.usermem | awk '{printf "%d MB", $1/1024/1024}')"
    # vmctl reset vms で vm.conf 由来の設定も消えるため、-d / -i / -n で全パラメータを
    # 明示する。vm.conf を参照せず vmd が新規インスタンスとして起動する。
    _log "[${vmname}] vmctl start -b $bsdrd -m ${inst_mem} -d ${disk} -i 1 -n ${swname} $vmname"
    vmctl start -b "$bsdrd" -m "${inst_mem}" -d "${disk}" -i 1 -n "${swname}" "$vmname"
    _info "    インストール中 (数分かかります)..."
    _log "[${vmname}] SSH 待機開始 (最大 10 分)..."
    _wait_ssh "$vmip"
    _log "[${vmname}] SSH 接続確認完了"
    _ok "${vmname} インストール完了"
}

_wait_ssh() {
    local ip="$1"
    local n=0
    while [ "$n" -lt 120 ]; do
        if ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=4 \
               -o BatchMode=yes "root@${ip}" true 2>/dev/null; then
            return 0
        fi
        n=$((n + 1))
        # 30 秒ごとに進捗ログ
        if [ $((n % 6)) -eq 0 ]; then
            _log "  SSH 待機中 ${ip} ... $((n * 5)) 秒経過 / 600 秒"
        fi
        sleep 5
    done
    _log "SSH タイムアウト — vmctl status:"
    vmctl status 2>/dev/null | while read -r l; do _log "  $l"; done
    _die "${ip} への SSH がタイムアウト (10 分)"
}

# 前回実行の残骸で stopped 状態の VM エントリが残っている場合、
# vmctl start -b で EALREADY が返る。vmctl reset vms で全 VM エントリを
# 一掃してからインストールを開始する。スイッチ定義・vm.conf は不変。
_log "インストール前 VM エントリクリア (vmctl reset vms)..."
vmctl reset vms 2>/dev/null || true
sleep 1
_log "リセット後 VM 一覧: $(vmctl status 2>/dev/null | awk 'NR>1{c++}END{print c+0}') 件"

_vm_install "vm-db"    "$OWL_DB_IP"    "$HOST_INT_IP"  "/var/vmm/db.img"    "internal_lan"
_vm_install "vm-git"   "$OWL_GIT_IP"  "$HOST_DEV_IP"  "/var/vmm/git.img"   "dev_lan"
_vm_install "vm-build" "$OWL_BUILD_IP" "$HOST_DEV_IP" "/var/vmm/build.img" "dev_lan"
_vm_install "vm-ap"    "$OWL_AP_IP"   "$HOST_INT_IP"  "/var/vmm/ap.img"    "internal_lan"

# ── STEP 6: VM 内部プロビジョニング ──────────────────────
_step 6 "VM 内部プロビジョニング"

_vm_provision() {
    local vmname="$1" vmip="$2"
    _info "-- ${vmname} (${vmip})"
    _log "[${vmname}] プロビジョニング開始"

    # VM のホスト鍵を known_hosts に記録する (owl-control.sh で StrictHostKeyChecking=yes に使用)
    _log "[${vmname}] ホスト鍵を ssh-keyscan で取得..."
    ssh-keyscan -T 10 "$vmip" >> /etc/owl/known_hosts 2>/dev/null
    _info "    ホスト鍵を /etc/owl/known_hosts に記録"

    # スクリプトと設定ファイルを VM に転送
    _log "[${vmname}] /provision ディレクトリを作成..."
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "install -d /provision"
    _log "[${vmname}] ${SELF}/${vmname}/ を VM に転送..."
    scp -i "$PROV_KEY" -o StrictHostKeyChecking=no -rq \
        "${SELF}/${vmname}/" "${SELF}/owl-config.toml" \
        "root@${vmip}:/provision/"
    _log "[${vmname}] 転送完了"

    # DR バックアップ鍵を authorized_keys に追加 (owl-control.sh 用)
    _log "[${vmname}] DR バックアップ鍵を authorized_keys に追加..."
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "install -d -m 700 /root/.ssh
         grep -qF '${BACKUP_PUBKEY}' /root/.ssh/authorized_keys 2>/dev/null || \
             echo '${BACKUP_PUBKEY}' >> /root/.ssh/authorized_keys
         chmod 600 /root/.ssh/authorized_keys"

    # setup.sh を実行
    _log "[${vmname}] setup.sh を実行中..."
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "OWL_AP_IP='${OWL_AP_IP}' OWL_DB_IP='${OWL_DB_IP}' \
         OWL_GIT_IP='${OWL_GIT_IP}' OWL_BUILD_IP='${OWL_BUILD_IP}' \
         OWL_RELEASE='${OWL_RELEASE}' GHC_VERSION='${GHC_VERSION}' \
         PG_VERSION='${PG_VERSION}' FORGEJO_VERSION='${FORGEJO_VER}' \
         sh /provision/${vmname}/setup.sh"
    _log "[${vmname}] setup.sh 完了"

    # プロビジョニング用の使い捨て鍵を VM から削除
    _log "[${vmname}] プロビジョニング鍵を VM から削除..."
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" "
        grep -v 'owl-prov-' /root/.ssh/authorized_keys > /root/.ssh/ak.tmp || true
        mv /root/.ssh/ak.tmp /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    "
    _log "[${vmname}] プロビジョニング完了"
    _ok "${vmname} 完了"
}

_vm_provision "vm-db"    "$OWL_DB_IP"
_vm_provision "vm-git"   "$OWL_GIT_IP"
_vm_provision "vm-build" "$OWL_BUILD_IP"
_vm_provision "vm-ap"    "$OWL_AP_IP"

# ── STEP 7: 本番封鎖 ─────────────────────────────────────
_step 7 "本番封鎖"

# DHCP / HTTP プロビジョニングサーバーを停止
_log "DHCP / HTTP プロビジョニングサーバーを停止..."
rcctl stop dhcpd 2>/dev/null || true
rcctl stop httpd 2>/dev/null || true
rcctl disable dhcpd 2>/dev/null || true
rcctl disable httpd 2>/dev/null || true
rm -rf /tmp/owl-install-www /tmp/dhcpd-prov.conf /tmp/httpd-prov.conf
_ok "プロビジョニングサーバー停止"

# プロビジョニング用の使い捨て鍵を削除
_log "プロビジョニング SSH 鍵を削除: ${PROV_KEY}"
rm -f "$PROV_KEY" "${PROV_KEY}.pub"
_ok "プロビジョニング SSH 鍵削除"

# IP フォワーディング無効化 + 本番 PF ルール適用
# sshd は pf.conf で通過させているのでロックアウトしない
# Yubikey 未着のため pf.conf の SSH pass ルールは現時点で有効
_log "IP フォワーディングを無効化..."
sysctl net.inet.ip.forwarding=0
_log "本番 pf.conf を配置して適用..."
install -m 600 "${SELF}/host/pf.conf"       /etc/pf.conf
install -m 644 "${SELF}/host/rc.conf.local" /etc/rc.conf.local
pfctl -f /etc/pf.conf
_log "pfctl -s rules:"
pfctl -s rules 2>/dev/null | while read -r l; do _log "  $l"; done
_ok "本番 PF 適用 (NAT 解除・封鎖)"

# 改ざん検知ベースライン記録 (§5)
_log "改ざん検知ベースラインを計算中..."
find /etc /usr/local/sbin -type f 2>/dev/null | sort \
    | xargs sha256 > /etc/owl/integrity-baseline.sha256
_log "ベースライン: $(wc -l < /etc/owl/integrity-baseline.sha256) ファイルを記録"
_ok "改ざん検知ベースライン記録"

# age 受信者公開鍵の確認
if [ ! -f "$(_toml "dr" "age_pubkey_file")" ]; then
    _info ""
    _info "⚠  age 受信者公開鍵が未配置です。DR 射出を有効にするには:"
    _info "   エスクロー (§2.3) から公開鍵を取り出し、以下に配置してください:"
    _info "   $(_toml "dr" "age_pubkey_file")"
fi

trap - EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " プロビジョニング完了 ✓"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " 【Yubikey が届いたら】"
echo "   この SSH セッションから直接実行:"
echo "   sh /etc/owl/infra/host/yubikey-setup.sh"
echo ""
echo " 【初回セットアップの続き】"
echo "   vm-db   : psql で owl スキーマ・RLS を適用"
echo "   vm-git  : Forgejo Web UI 初期化 → Runner トークン発行"
echo "   vm-build: forgejo-runner register でトークン登録"
echo ""
echo " 【DR 復元の場合】"
echo "   age identity をエスクロー (§2.3) から取り出し"
echo "   射出先ストレージから最新アーカイブを取得・復号 (§2.4 手順5)"