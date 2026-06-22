#!/bin/sh
# dev-join.sh — 開発メンバー用 git-jump アカウントの追加 / 削除
#
# git-jump アカウントは Forgejo Web UI (:3000 ローカルポートフォワード) と
# git push (:22) への SSH トンネルのみを許可する no-shell アカウント
# (infra/host/steps/01-host-foundation.sh の Match Group owl-git-jump 参照。
# ForceCommand /bin/false + PermitTTY no + PermitOpen <GIT_IP>:22 <GIT_IP>:3000)。
# root にも wheel にも一切昇格できない。
#
# 【重要・GitOps】このスクリプトはホスト上の /etc/owlv/infra/ (rsync で送り込んだ
# コピー) を直接更新する。これは provision.sh を再実行すれば消えてしまう一時的な
# 変更でしかないため、必ずローカルの開発リポジトリ側
# (infra/host/conf/git-jump-keys/<username>.pub) にも同じ鍵を追加してコミットし、
# 次回 rsync で配布すること (§4.3: インフラはコードから 100% 再生成可能に保つ)。
#
# 使い方:
#   doas sh dev-join.sh <username> <pubkey-file>   追加 (既存なら鍵を上書き)
#   doas sh dev-join.sh <username> --remove        無効化 (OS アカウントはロックのみ)
set -eu

GIT_JUMP_KEYS_DIR=/etc/owlv/infra/host/conf/git-jump-keys
GIT_JUMP_GROUP=owl-git-jump
CONFIG=/etc/owlv/infra/owl-config.toml

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_info() { _log "    $*"; }
_ok() { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root (doas) で実行してください"

USERNAME="${1:-}"
ARG2="${2:-}"
[ -n "$USERNAME" ] && [ -n "$ARG2" ] ||
	_die "使い方: dev-join.sh <username> <pubkey-file> | dev-join.sh <username> --remove"

# OpenBSD useradd のユーザー名制約 (英小文字/数字/-/_ 、先頭は英小文字か _) を
# 軽く事前検証する。OS コマンドへそのまま渡す変数なので形式を絞っておく。
case "$USERNAME" in
[a-z_][a-z0-9_-]*) ;;
*) _die "username は英小文字で始まり、英小文字/数字/-/_ のみで構成してください: ${USERNAME}" ;;
esac

install -d -m 755 "$GIT_JUMP_KEYS_DIR"
groupadd "$GIT_JUMP_GROUP" 2>/dev/null || true

_toml() {
	awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k { gsub(/^[^=]+=[ "]*|["]*$/,""); print; exit }
    ' "$CONFIG"
}

if [ "$ARG2" = "--remove" ]; then
	_log "git-jump アカウントを無効化: ${USERNAME}"
	rm -f "${GIT_JUMP_KEYS_DIR}/${USERNAME}.pub"
	if id "$USERNAME" >/dev/null 2>&1; then
		usermod -L "$USERNAME" 2>/dev/null || true
		: >"/home/${USERNAME}/.ssh/authorized_keys" 2>/dev/null || true
		_ok "${USERNAME} を無効化しました (OS アカウント自体は残置。完全削除は別途 userdel -r)"
	else
		_info "${USERNAME} は元々存在しません"
	fi
	echo ""
	echo "【ローカルリポジトリ側でも忘れずに】"
	echo "  infra/host/conf/git-jump-keys/${USERNAME}.pub を削除してコミットしてください"
	exit 0
fi

PUBKEY_FILE="$ARG2"
[ -f "$PUBKEY_FILE" ] || _die "公開鍵ファイルが見つかりません: ${PUBKEY_FILE}"
# 簡易フォーマット検証 (ssh-ed25519 / ssh-rsa / ecdsa-sha2-* で始まる1行を想定)
head -1 "$PUBKEY_FILE" | grep -qE '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)' ||
	_die "公開鍵の形式が不正です (ssh-ed25519 等で始まる1行を想定): ${PUBKEY_FILE}"

_log "git-jump アカウントを追加: ${USERNAME}"
cp "$PUBKEY_FILE" "${GIT_JUMP_KEYS_DIR}/${USERNAME}.pub"
chmod 644 "${GIT_JUMP_KEYS_DIR}/${USERNAME}.pub"

if id "$USERNAME" >/dev/null 2>&1; then
	usermod -G "$GIT_JUMP_GROUP" -s /sbin/nologin "$USERNAME"
	usermod -U "$USERNAME" 2>/dev/null || true # --remove からの復帰用にロック解除
else
	useradd -m -G "$GIT_JUMP_GROUP" -s /sbin/nologin "$USERNAME"
fi
install -d -m 700 -o "$USERNAME" -g "$GIT_JUMP_GROUP" "/home/${USERNAME}/.ssh"
install -m 600 -o "$USERNAME" -g "$GIT_JUMP_GROUP" \
	"${GIT_JUMP_KEYS_DIR}/${USERNAME}.pub" "/home/${USERNAME}/.ssh/authorized_keys"
_ok "${USERNAME} 追加完了"

GIT_IP=$(_toml "network.dev_lan" "git_vm")

echo ""
echo "【ローカルリポジトリ側でも忘れずに】"
echo "  infra/host/conf/git-jump-keys/${USERNAME}.pub をコミットしてください"
echo "  (provision.sh 再実行時にこのアカウントが再生成されるようにするため)"
echo ""
echo "【${USERNAME} 本人への案内】"
echo "  ssh -N -L 3000:${GIT_IP:-<GIT_VM_IP>}:3000 ${USERNAME}@<このホストのLAN IP>"
echo "  ブラウザで http://localhost:3000 (Forgejo Web UI)"
echo "  git push 用 (任意): ~/.ssh/config に以下を追加すると ProxyJump で直接 push できる"
echo "    Host owlv-git"
echo "        HostName ${GIT_IP:-<GIT_VM_IP>}"
echo "        User git"
echo "        ProxyJump ${USERNAME}@<このホストのLAN IP>"
