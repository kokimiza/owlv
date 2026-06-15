#!/bin/sh
# provision.sh — owlv ベアメタルリストア
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
#   # (1) infra ディレクトリごと /tmp/ に転送 → /tmp/infra/ になる
#   scp -r infra <YOUR_USERNAME>@192.168.50.200:/tmp/
#
#   # (2) SSH ログイン後、/etc/owl/ に配置して実行
#   ssh <YOUR_USERNAME>@192.168.50.200
#   doas rm -rf /etc/owl/ && doas mv /tmp/infra/ /etc/owl/
#   doas sh /etc/owl/provision.sh
#
#   ※ 再実行時は同じ手順。/etc/owl/ ごと上書きするので古い残骸は自動的に消える。
#
# ━━━ 【Yubikey が届いたら】━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#   ssh <YOUR_USERNAME>@<HOST_IP> 'doas sh /etc/owl/host/security/yubikey-setup.sh'
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

_vmctl_status_to() {
    local out="$1" err="${1}.err"

    if vmctl status >"$out" 2>"$err"; then
        rm -f "$err"
        return 0
    fi

    # switch-only の /etc/vm.conf では VM 行が無く、環境によっては
    # ヘッダを出していても vmctl status が非 0 を返す。ヘッダが取れて
    # いれば vmd は応答しているものとして扱う。
    if grep -q 'OWNER.*STATE.*NAME' "$out" 2>/dev/null; then
        rm -f "$err"
        return 0
    fi

    return 1
}

_vmctl_status_ok() {
    local out="/tmp/owl-vmctl-status.$$"

    if _vmctl_status_to "$out"; then
        rm -f "$out" "${out}.err"
        return 0
    fi
    rm -f "$out" "${out}.err"
    return 1
}

_log_vmctl_status() {
    local prefix="$1" out="/tmp/owl-vmctl-status.$$"

    if _vmctl_status_to "$out"; then
        while read -r l; do _log "  ${prefix}${l}"; done < "$out"
        rm -f "$out" "${out}.err"
        return 0
    fi

    if [ -s "${out}.err" ]; then
        while read -r l; do _log "  ${prefix}${l}"; done < "${out}.err"
    fi
    rm -f "$out" "${out}.err"
    return 1
}

_bridge_members() {
    local ifn="$1" members

    members=$(ifconfig "$ifn" 2>/dev/null | awk '
        /^[[:space:]]+member:/ { printf "%s ", $2 }
        /^[[:space:]]+[[:alnum:]_]+[0-9]+[[:space:]]+flags=/ { printf "%s ", $1 }
    ')
    printf '%s\n' "${members:-'(なし)'}"
}

_vm_state_for() {
    local vmname="$1" out="/tmp/owl-vmctl-state.$$" state

    if _vmctl_status_to "$out"; then
        state=$(awk -v n="$vmname" 'NR>1 && $NF==n{print $(NF-1); exit}' "$out")
        rm -f "$out" "${out}.err"
        printf '%s\n' "$state"
        return 0
    fi
    rm -f "$out" "${out}.err"
    return 1
}

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
_log "provision.sh: ${SELF}/provision.sh checksum=$(cksum "$0" | awk '{print $1 ":" $2}')"

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

# ── ステップ実行 ───────────────────────────────────────────
STEPS_DIR="${SELF}/host/steps"

. "${STEPS_DIR}/01-foundation.sh"
. "${STEPS_DIR}/02-network.sh"
. "${STEPS_DIR}/03-disks.sh"
. "${STEPS_DIR}/04-sshkeys.sh"
. "${STEPS_DIR}/05-vm-install.sh"
. "${STEPS_DIR}/06-vm-provision.sh"
. "${STEPS_DIR}/07-lockdown.sh"

trap - EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " プロビジョニング完了 ✓"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " 【Yubikey が届いたら】"
echo "   この SSH セッションから直接実行:"
echo "   sh /etc/owl/infra/host/security/yubikey-setup.sh"
echo ""
echo " 【初回セットアップの続き】"
echo "   vm-db   : psql で owl スキーマ・RLS を適用"
echo "   vm-git  : Forgejo Web UI 初期化 → Runner トークン発行"
echo "   vm-build: forgejo-runner register でトークン登録"
echo ""
echo " 【DR 復元の場合】"
echo "   age identity をエスクロー (§2.3) から取り出し"
echo "   射出先ストレージから最新アーカイブを取得・復号 (§2.4 手順5)"
