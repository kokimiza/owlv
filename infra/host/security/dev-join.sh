#!/bin/sh
# dev-join.sh — 開発メンバー用 git-jump アカウントの追加 / 削除 / 同期
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
#   doas sh dev-join.sh sync                        ${GIT_JUMP_KEYS_DIR}/*.pub と
#                                                    OS アカウントを完全一致させる
#                                                    (*.pub が無いメンバーは無効化)
#
# sync は infra/host/steps/01-host-foundation.sh の provision 時にも呼ばれる
# (冪等・再現可能にするため、運用中の手動同期と provision 時の処理を1本化)。
#
# パスワードは一切登場しない (アカウントは -s /sbin/nologin + ForceCommand
# /bin/false で shell 自体が無く、doas できるグループにも入れない。認証は
# SSH 鍵のみ)。新規メンバーを入れる作業は以下の2役で完全に分かれる。
#
# 【開発担当者 (新規メンバー本人) がやること】
#   1. 開発機側で git-jump 専用の鍵を新規生成する (ホスト管理者SSH/rsync用の
#      鍵とは別物。使い回さない):
#        ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_gitjump -C "<username>-gitjump"
#      username は OpenBSD useradd の制約に合わせて英小文字始まり/英小文字・
#      数字・_ のみ (- は使わない、下記 case 文参照)。既存の管理者ログイン名と一致させる
#      必要はない。パスフレーズは自分の好きなものを設定してよい (これは
#      秘密鍵をローカルで保護するためだけのもので、ホスト側には関係ない)。
#   2. 生成した ~/.ssh/id_ed25519_gitjump.pub を、ローカルの開発リポジトリの
#      infra/host/conf/git-jump-keys/<username>.pub へ mv し、git commit ＆
#      push する。これで本人の作業は完了。
#
# 【開発責任者 (ホスト管理者) がやること】
#   1. 最新を rsync (上記でpushされた <username>.pub がホストへ配布される)。
#   2. ホスト上で root (doas) としてこのスクリプトを1回実行するだけ:
#        doas sh dev-join.sh <username> ${GIT_JUMP_KEYS_DIR}/<username>.pub
#      もしくは複数人まとめて反映するだけなら sync で十分:
#        doas sh dev-join.sh sync
#      これだけで OS アカウント作成・authorized_keys 登録まで完了する。
#      事前の手動アカウント作成やファイル操作は不要。対話的な入力も無い。
#      退会させる場合も同様に1コマンド: doas sh dev-join.sh <username> --remove
#
# 完了すると、開発担当者は (責任者から何も連絡を受けずに) すぐ以下で
# パスワードレス接続できる。最初に聞かれるのは ①で自分が決めた鍵の
# パスフレーズだけ:
#   ssh -i ~/.ssh/id_ed25519_gitjump -N -L 3000:<GIT_VM_IP>:3000 <username>@<ホストのLAN IP>
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

_toml() {
	awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k { gsub(/^[^=]+=[ "]*|["]*$/,""); print; exit }
    ' "$CONFIG"
}

install -d -m 755 "$GIT_JUMP_KEYS_DIR"
groupadd "$GIT_JUMP_GROUP" 2>/dev/null || true

# ${GIT_JUMP_KEYS_DIR}/<user>.pub が既に存在する前提で、その内容を
# authorized_keys に反映しつつ OS アカウントを作成/更新する (--remove や
# sync 後の復帰でロックも解除する)。単体追加・sync の両方から呼ばれる。
_sync_one_user() {
	_user="$1"
	if id "$_user" >/dev/null 2>&1; then
		usermod -G "$GIT_JUMP_GROUP" -s /sbin/nologin "$_user"
		usermod -U "$_user" 2>/dev/null || true # ロック解除 (--remove/sync無効化からの復帰用)
	else
		useradd -m -G "$GIT_JUMP_GROUP" -s /sbin/nologin "$_user"
	fi
	install -d -m 700 -o "$_user" -g "$GIT_JUMP_GROUP" "/home/${_user}/.ssh"
	install -m 600 -o "$_user" -g "$GIT_JUMP_GROUP" \
		"${GIT_JUMP_KEYS_DIR}/${_user}.pub" "/home/${_user}/.ssh/authorized_keys"
}

# OS アカウントをロックし authorized_keys を空にする。完全削除はしない
# (userdel -r は別途手動で。ホームディレクトリ等を不可逆に消すため)。
_disable_user() {
	_user="$1"
	if id "$_user" >/dev/null 2>&1; then
		usermod -L "$_user" 2>/dev/null || true
		: >"/home/${_user}/.ssh/authorized_keys" 2>/dev/null || true
	fi
}

# ── sync モード: ディレクトリの *.pub と OS アカウントを完全一致させる ──
if [ "${1:-}" = "sync" ]; then
	_log "git-jump アカウントを同期 (${GIT_JUMP_KEYS_DIR}/*.pub)..."
	_n=0
	for _pub in "${GIT_JUMP_KEYS_DIR}"/*.pub; do
		[ -f "$_pub" ] || continue
		_sync_one_user "$(basename "$_pub" .pub)"
		_info "git-jump アカウント: $(basename "$_pub" .pub)"
		_n=$((_n + 1))
	done
	[ "$_n" -gt 0 ] || _info "鍵が見つかりません。追加するには ${GIT_JUMP_KEYS_DIR}/<user>.pub を配置してください"

	# *.pub が無くなったのにアカウントが残っているメンバーを無効化する
	# (退職時に .pub を消して commit するだけで、次回 sync で自動的に
	# 失効させたい。/etc/group の該当グループの第4フィールド (メンバー一覧、
	# カンマ区切り) を見る。OpenBSD には getent が無いため直接 awk で読む)。
	_members=$(awk -F: -v g="$GIT_JUMP_GROUP" '$1==g{print $4}' /etc/group)
	_disabled=0
	if [ -n "$_members" ]; then
		_oldifs=$IFS
		IFS=,
		for _m in $_members; do
			IFS=$_oldifs
			[ -f "${GIT_JUMP_KEYS_DIR}/${_m}.pub" ] && continue
			_disable_user "$_m"
			_info "無効化 (対応する .pub が無い): ${_m}"
			_disabled=$((_disabled + 1))
		done
		IFS=$_oldifs
	fi
	_ok "git-jump アカウント同期 (${_n} 件有効、${_disabled} 件無効化)"
	exit 0
fi

USERNAME="${1:-}"
ARG2="${2:-}"
[ -n "$USERNAME" ] && [ -n "$ARG2" ] ||
	_die "使い方: dev-join.sh <username> <pubkey-file> | dev-join.sh <username> --remove | dev-join.sh sync"

# ユーザー名制約 (英小文字/数字/_ のみ、先頭は英小文字か _、- は使わない) を
# 軽く事前検証する。OS コマンドへそのまま渡す変数なので形式を絞っておく。
case "$USERNAME" in
[a-z_][a-z0-9_]*) ;;
*) _die "username は英小文字で始まり、英小文字/数字/_ のみで構成してください(- は使用不可): ${USERNAME}" ;;
esac

if [ "$ARG2" = "--remove" ]; then
	_log "git-jump アカウントを無効化: ${USERNAME}"
	rm -f "${GIT_JUMP_KEYS_DIR}/${USERNAME}.pub"
	if id "$USERNAME" >/dev/null 2>&1; then
		_disable_user "$USERNAME"
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
_sync_one_user "$USERNAME"
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
