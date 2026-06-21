#!/bin/sh
# ap-admin-user.sh — AP VM に root_admin_username の OS アカウントを作成
#
# owl-config.toml [user] root_admin_username は owlv が Admin ロールを
# 自動付与する唯一の OS ユーザー名 (doc/user.md §7)。このユーザー自体は
# owl-user-sync の管轄外 (鶏卵問題) なので、provision.sh では作成できず
# AP VM 上に手動で作る必要がある (vm-ap/setup.sh 終端コメント参照)。
#
# 【実行タイミング】STEP 9 (本番封鎖) 完了後、AP VM への SSH 到達性がある間に。
#   このユーザーで初回 SSH すると owlv が Admin/Active な User を自動生成する。
#
# 【前提条件】
#   - provision.sh が完了済み (BACKUP_KEY が host/known_hosts に確立済み)
#   - 作成したい OS アカウントの SSH 公開鍵を手元に用意しておくこと
set -eu

CONFIG=/etc/owl/infra/owl-config.toml
KNOWN_HOSTS=/etc/owl/known_hosts
BACKUP_KEY=/etc/owl/backup_ed25519

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_info() { _log "    $*"; }

[ "$(id -u)" -eq 0 ] || _die "root (doas) で実行してください"
[ -f "$CONFIG" ] || _die "$CONFIG が見つかりません"
[ -f "$BACKUP_KEY" ] || _die "$BACKUP_KEY が見つかりません。provision.sh STEP 6/8 が未完了です"

_toml() {
	awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k { gsub(/^[^=]+=[ "]*|["]*$/,""); print; exit }
    ' "$CONFIG"
}

AP_IP=$(_toml "network.internal_lan" "ap_vm")
ROOT_ADMIN_USERNAME=$(_toml "user" "root_admin_username")

[ -n "$AP_IP" ] || _die "owl-config.toml [network.internal_lan] ap_vm が未設定"
[ -n "$ROOT_ADMIN_USERNAME" ] || _die "owl-config.toml [user] root_admin_username が未設定"

_ssh() {
	ssh -i "$BACKUP_KEY" \
		-o StrictHostKeyChecking=yes \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o BatchMode=yes \
		-o ConnectTimeout=10 \
		"root@${AP_IP}" "$@"
}

_log "AP VM (${AP_IP}) に管理者アカウント '${ROOT_ADMIN_USERNAME}' を作成します"

if _ssh "id ${ROOT_ADMIN_USERNAME} >/dev/null 2>&1"; then
	_info "${ROOT_ADMIN_USERNAME} は既に存在します → ユーザー作成はスキップ"
else
	_ssh "useradd -m -G owl-maintainers -s /bin/ksh '${ROOT_ADMIN_USERNAME}'" ||
		_die "useradd に失敗しました"
	_log "OS アカウント作成完了"
fi

echo ""
echo "${ROOT_ADMIN_USERNAME} の SSH 公開鍵を貼り付けてください (1行、ssh-ed25519 ... 形式):"
printf "> "
read -r ADMIN_PUBKEY

case "$ADMIN_PUBKEY" in
ssh-* | ecdsa-* | sk-*) ;;
*) _die "公開鍵の形式が不正です (ssh-ed25519 / ssh-rsa / ecdsa-... で始まる必要があります)" ;;
esac

_ssh "install -d -m 700 -o ${ROOT_ADMIN_USERNAME} /home/${ROOT_ADMIN_USERNAME}/.ssh
     touch /home/${ROOT_ADMIN_USERNAME}/.ssh/authorized_keys
     grep -qF '${ADMIN_PUBKEY}' /home/${ROOT_ADMIN_USERNAME}/.ssh/authorized_keys 2>/dev/null ||
         echo '${ADMIN_PUBKEY}' >> /home/${ROOT_ADMIN_USERNAME}/.ssh/authorized_keys
     chmod 600 /home/${ROOT_ADMIN_USERNAME}/.ssh/authorized_keys
     chown ${ROOT_ADMIN_USERNAME} /home/${ROOT_ADMIN_USERNAME}/.ssh/authorized_keys" ||
	_die "authorized_keys の更新に失敗しました"

_log "authorized_keys 更新完了"
_log "確認: ssh ${ROOT_ADMIN_USERNAME}@${AP_IP} -p \$(grep ssh_port -A0 owl-config.toml)"
echo ""
echo "このユーザーで初回 SSH すると owlv が Admin/Active な User を自動生成します。"
