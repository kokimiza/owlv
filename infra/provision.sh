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
#   rsync -avn --delete infra/ <YOUR_USERNAME>@192.168.50.200:/tmp/infra/
#   ssh <YOUR_USERNAME>@<HOST_IP> \
#       "install -d /etc/owl && doas mv /tmp/infra /etc/owl/infra && \
#        doas sh /etc/owl/infra/provision.sh"
#
# ━━━ 【Yubikey が届いたら】━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#   ssh <YOUR_USERNAME>@<HOST_IP> 'doas sh /etc/owl/infra/host/yubikey-setup.sh'
#
# この時点では SSH を維持する。
# Yubikey セットアップ完了まで管理者がロックアウトされないようにするため。

set -eu
trap '_on_exit $?' EXIT

_on_exit() {
    local rc=$1
    if [ "$rc" -ne 0 ]; then
        echo ""
        echo "エラー終了 (exit $rc)。PF ルールを安全な暫定状態に維持します。"
        echo "再実行: sh /etc/owl/infra/provision.sh"
    fi
}

_die()  { echo "エラー: $*" >&2; exit 1; }
_step() { printf '\n━━━ [%s/%s] %s\n' "$1" "$TOTAL" "$2"; }
_ok()   { echo "    ✓ $*"; }
_info() { echo "      $*"; }

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"
[ "$(uname)" = "OpenBSD" ] || _die "OpenBSD でのみ実行可能"

SELF="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SELF}/owl-config.toml"
TOTAL=7

[ -f "$CONFIG" ] || _die "$CONFIG が見つかりません"

# ── TOML 読み込み ──────────────────────────────────────────
_toml() {
    awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k { gsub(/^[^=]+=[ "]*|["]*$/,""); print; exit }
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

HOST_INT_IP="10.0.1.1"
HOST_DEV_IP="10.0.2.1"
PROV_KEY=/etc/owl/prov_ed25519      # プロビジョニング用の使い捨て SSH 鍵
BACKUP_KEY=/etc/owl/backup_ed25519  # DR 用の恒久 SSH 鍵 (owl-control.sh が使用)
LOGDIR=/var/log/owl

export OWL_AP_IP OWL_DB_IP OWL_GIT_IP OWL_BUILD_IP \
       OWL_RELEASE GHC_VERSION PG_VERSION FORGEJO_VER

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " owlv プロビジョニング (OpenBSD ${OWL_RELEASE})"
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

# 設定ファイルを配置 (vmd.conf / doas.conf / newsyslog.conf / crontab)
# pf.conf と rc.conf.local は STEP 7 の本番封鎖時に適用する
install -m 600 "${SELF}/host/vmd.conf"       /etc/vm.conf
install -m 644 "${SELF}/host/doas.conf"      /etc/doas.conf
install -m 644 "${SELF}/host/newsyslog.conf" /etc/newsyslog.conf
install -m 600 "${SELF}/host/crontab"        /etc/crontab
_ok "設定ファイル配置"

# owl-control 専用ユーザー
id owl-control >/dev/null 2>&1 || useradd -s /sbin/nologin -d /nonexistent owl-control

# 必要パッケージ (この時点では外向き通信が開いているので pkg_add で取得)
pkg_add age rclone 2>/dev/null && _ok "age / rclone インストール" || \
    _info "警告: age / rclone の自動インストール失敗。後で手動実行: pkg_add age rclone"

# vmd を起動 (vether0/1 がここで生成される)
rcctl enable vmd
rcctl start vmd 2>/dev/null || rcctl restart vmd
sleep 2   # vether インターフェース生成を待つ
_ok "vmd 起動"

# ── STEP 2: 仮想ネットワーク ──────────────────────────────
_step 2 "仮想ネットワーク設定"

# ホストを両 LAN のゲートウェイとして設定
cat > /etc/hostname.vether0 <<EOF
inet ${HOST_INT_IP} 255.255.255.0
description "internal_lan gateway"
EOF
cat > /etc/hostname.vether1 <<EOF
inet ${HOST_DEV_IP} 255.255.255.0
description "dev_lan gateway"
EOF
ifconfig vether0 inet "${HOST_INT_IP}" 255.255.255.0 up
ifconfig vether1 inet "${HOST_DEV_IP}" 255.255.255.0 up
_ok "vether0 (${HOST_INT_IP}) / vether1 (${HOST_DEV_IP}) 設定"

# VM がミラーからインストールセットを取得できるよう IP フォワーディング + NAT を有効化
# (本番封鎖は STEP 7 で適用するため、ここでは最小限のルールのみ)
sysctl net.inet.ip.forwarding=1
cat | pfctl -f - <<PFEOF
# プロビジョニング中の暫定 PF ルール
# NAT: VM → インターネット (OpenBSD ミラーからインストールセットを取得)
match out on ${WAN_IF} from { 10.0.1.0/24, 10.0.2.0/24 } nat-to (${WAN_IF})

set block-policy drop
set skip on lo0
block all

# SSH: 管理アクセスを維持 (Yubikey セットアップ完了まで維持する §yubikey-setup.sh)
pass in on ${WAN_IF} proto tcp to port 22

# VM ↔ ホスト: DHCP / HTTP (autoinstall) + SSH (プロビジョニング)
pass on vether0 all
pass on vether1 all

# VM → インターネット: インストールセット取得のみ
pass out on ${WAN_IF} all
PFEOF
_ok "暫定 PF (NAT) 適用"

# ── STEP 3: VM ディスクイメージ作成 ──────────────────────
_step 3 "VM ディスクイメージ作成"
install -d /var/vmm
for spec in "ap:20G" "db:50G" "git:50G" "build:50G"; do
    name="${spec%%:*}"; size="${spec##*:}"; img="/var/vmm/${name}.img"
    if [ ! -f "$img" ]; then
        vmctl create -s "$size" "$img" && _ok "${name}.img (${size}) 作成"
    else
        _info "${name}.img 既存のためスキップ"
    fi
done

# ── STEP 4: SSH 鍵生成 ────────────────────────────────────
_step 4 "SSH 鍵生成"

# プロビジョニング用の使い捨て鍵 (STEP 7 で削除)
ssh-keygen -t ed25519 -N "" -C "owl-prov-$(date +%Y%m%d)" -f "$PROV_KEY" -q
chmod 600 "$PROV_KEY"
PROV_PUBKEY="$(cat ${PROV_KEY}.pub)"
_ok "プロビジョニング鍵: ${PROV_KEY}"

# DR バックアップ用の恒久鍵 (owl-control.sh が VM に SSH するために使用)
if [ ! -f "$BACKUP_KEY" ]; then
    ssh-keygen -t ed25519 -N "" -C "owl-backup" -f "$BACKUP_KEY" -q
    chmod 600 "$BACKUP_KEY"
    _ok "DR バックアップ鍵: ${BACKUP_KEY} (各 VM の authorized_keys に追加される)"
else
    _info "DR バックアップ鍵: ${BACKUP_KEY} 既存のため再利用"
fi
BACKUP_PUBKEY="$(cat ${BACKUP_KEY}.pub)"

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
rcctl set dhcpd flags "-c /tmp/dhcpd-prov.conf vether0 vether1"
rcctl start dhcpd 2>/dev/null || rcctl restart dhcpd

install -d /tmp/owl-install-www
cat > /tmp/httpd-prov.conf <<HTTP
server "prov" {
    listen on ${HOST_INT_IP} port 80
    listen on ${HOST_DEV_IP} port 80
    root "/tmp/owl-install-www"
    directory auto index
}
HTTP
rcctl set httpd flags "-f /tmp/httpd-prov.conf"
rcctl start httpd 2>/dev/null || rcctl restart httpd
_ok "DHCP / HTTP サーバー起動"

# ── STEP 5: VM OS インストール (autoinstall) ─────────────
_step 5 "VM OS autoinstall"
_info "install.conf を自動生成し、1 台ずつ順番にインストールします。"
_info "インストールセットは ${OBD_MIRROR} から取得します。"

_vm_install() {
    local vmname="$1" vmip="$2" gateway="$3"

    _info "-- ${vmname} (${vmip})"

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

    # bsd.rd で起動 (disk / memory は vm.conf から読む)
    local bsdrd="/var/vmm/bsd.rd-${OWL_RELEASE}"
    if [ ! -f "$bsdrd" ]; then
        _info "    bsd.rd を取得中..."
        ftp -o "$bsdrd" \
            "https://${OBD_MIRROR}/pub/OpenBSD/${OWL_RELEASE}/amd64/bsd.rd" \
            || _die "bsd.rd の取得に失敗しました"
    fi

    vmctl start -b "$bsdrd" "$vmname"
    _info "    インストール中 (数分かかります)..."
    _wait_ssh "$vmip"
    _ok "${vmname} インストール完了"
}

_wait_ssh() {
    local ip="$1"
    local n=0
    while [ "$n" -lt 120 ]; do
        ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=4 \
            -o BatchMode=yes "root@${ip}" true 2>/dev/null && return 0
        n=$((n + 1)); sleep 5
    done
    _die "${ip} への SSH がタイムアウト (10 分)"
}

_vm_install "vm-db"    "$OWL_DB_IP"    "$HOST_INT_IP"
_vm_install "vm-git"   "$OWL_GIT_IP"  "$HOST_DEV_IP"
_vm_install "vm-build" "$OWL_BUILD_IP" "$HOST_DEV_IP"
_vm_install "vm-ap"    "$OWL_AP_IP"   "$HOST_INT_IP"

# ── STEP 6: VM 内部プロビジョニング ──────────────────────
_step 6 "VM 内部プロビジョニング"

_vm_provision() {
    local vmname="$1" vmip="$2"
    _info "-- ${vmname} (${vmip})"

    # VM のホスト鍵を known_hosts に記録する (owl-control.sh で StrictHostKeyChecking=yes に使用)
    ssh-keyscan -T 10 "$vmip" >> /etc/owl/known_hosts 2>/dev/null
    _info "    ホスト鍵を /etc/owl/known_hosts に記録"

    # スクリプトと設定ファイルを VM に転送
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "install -d /provision"
    scp -i "$PROV_KEY" -o StrictHostKeyChecking=no -rq \
        "${SELF}/${vmname}/" "${SELF}/owl-config.toml" \
        "root@${vmip}:/provision/"

    # DR バックアップ鍵を authorized_keys に追加 (owl-control.sh 用)
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "install -d -m 700 /root/.ssh
         grep -qF '${BACKUP_PUBKEY}' /root/.ssh/authorized_keys 2>/dev/null || \
             echo '${BACKUP_PUBKEY}' >> /root/.ssh/authorized_keys
         chmod 600 /root/.ssh/authorized_keys"

    # setup.sh を実行
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "OWL_AP_IP='${OWL_AP_IP}' OWL_DB_IP='${OWL_DB_IP}' \
         OWL_GIT_IP='${OWL_GIT_IP}' OWL_BUILD_IP='${OWL_BUILD_IP}' \
         OWL_RELEASE='${OWL_RELEASE}' GHC_VERSION='${GHC_VERSION}' \
         PG_VERSION='${PG_VERSION}' FORGEJO_VERSION='${FORGEJO_VER}' \
         sh /provision/${vmname}/setup.sh"

    # プロビジョニング用の使い捨て鍵を VM から削除
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" "
        grep -v 'owl-prov-' /root/.ssh/authorized_keys > /root/.ssh/ak.tmp || true
        mv /root/.ssh/ak.tmp /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    "
    _ok "${vmname} 完了"
}

_vm_provision "vm-db"    "$OWL_DB_IP"
_vm_provision "vm-git"   "$OWL_GIT_IP"
_vm_provision "vm-build" "$OWL_BUILD_IP"
_vm_provision "vm-ap"    "$OWL_AP_IP"

# ── STEP 7: 本番封鎖 ─────────────────────────────────────
_step 7 "本番封鎖"

# DHCP / HTTP プロビジョニングサーバーを停止
rcctl stop dhcpd 2>/dev/null || true
rcctl stop httpd 2>/dev/null || true
rcctl disable dhcpd 2>/dev/null || true
rcctl disable httpd 2>/dev/null || true
rm -rf /tmp/owl-install-www /tmp/dhcpd-prov.conf /tmp/httpd-prov.conf
_ok "プロビジョニングサーバー停止"

# プロビジョニング用の使い捨て鍵を削除
rm -f "$PROV_KEY" "${PROV_KEY}.pub"
_ok "プロビジョニング SSH 鍵削除"

# IP フォワーディング無効化 + 本番 PF ルール適用
# sshd は pf.conf で通過させているのでロックアウトしない
# Yubikey 未着のため pf.conf の SSH pass ルールは現時点で有効
sysctl net.inet.ip.forwarding=0
install -m 600 "${SELF}/host/pf.conf"       /etc/pf.conf
install -m 644 "${SELF}/host/rc.conf.local" /etc/rc.conf.local
pfctl -f /etc/pf.conf
_ok "本番 PF 適用 (NAT 解除・封鎖)"

# 改ざん検知ベースライン記録 (§5)
find /etc /usr/local/sbin -type f 2>/dev/null | sort \
    | xargs sha256 > /etc/owl/integrity-baseline.sha256
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