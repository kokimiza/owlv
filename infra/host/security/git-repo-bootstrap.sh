#!/bin/sh
# git-repo-bootstrap.sh — Forgejo に owlv リポジトリを作成
#
# vm-git/setup.sh は Forgejo 本体・admin ユーザー・Runner のオフライン登録までを
# 済ませるが、リポジトリ自体の作成は環境固有 (誰が owner になるか、いつ初回 push
# するか) なので provision.sh には組み込まず、ここで明示的に実行する。
#
# 【実行タイミング】STEP 9 (本番封鎖) 完了後。何度でも安全に再実行可能
# (既に存在する場合はスキップ)。
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
_ok() { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root (doas) で実行してください"
[ -f "$CONFIG" ] || _die "$CONFIG が見つかりません"
[ -f "$BACKUP_KEY" ] || _die "$BACKUP_KEY が見つかりません。provision.sh STEP 6/8 が未完了です"

_toml() {
	awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k { gsub(/^[^=]+=[ "]*|["]*$/,""); print; exit }
    ' "$CONFIG"
}

GIT_IP=$(_toml "network.dev_lan" "git_vm")
[ -n "$GIT_IP" ] || _die "owl-config.toml [network.dev_lan] git_vm が未設定"

_ssh() {
	ssh -i "$BACKUP_KEY" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o BatchMode=yes -o ConnectTimeout=10 "root@${GIT_IP}" "$@"
}

FORGEJO_DATA=/var/lib/forgejo

REPO_OWNER="admin"
REPO_NAME="owlv"

_log "Git VM (${GIT_IP}) に ${REPO_OWNER}/${REPO_NAME} を作成します"

if _ssh "su -m git -c \"forgejo admin repo list --config ${FORGEJO_DATA}/custom/conf/app.ini\" 2>/dev/null | grep -qiw '${REPO_NAME}'"; then
	_info "${REPO_OWNER}/${REPO_NAME} は既に存在します → スキップ"
else
	_ssh "su -m git -c \"forgejo admin repo create --owner ${REPO_OWNER} --name ${REPO_NAME} \
        --config ${FORGEJO_DATA}/custom/conf/app.ini\"" ||
		_die "リポジトリ作成に失敗しました"
	_ok "${REPO_OWNER}/${REPO_NAME} 作成完了"
fi

_log "Git リポジトリ準備完了"
echo ""
echo "【まだ残っている手動作業】"
echo "  1. admin の初期パスワードを変更 (provision.sh 実行ログ参照: /var/log/owl/provision-*.log)"
echo "  2. ローカルから push:"
echo "     git remote add origin ssh://git@${GIT_IP}:22/${REPO_OWNER}/${REPO_NAME}.git"
echo "     git push -u origin main"
echo "  3. .forgejo/workflows/build.yml が含まれていることを確認し"
echo "     Forgejo → ${REPO_NAME} → Actions タブで CI トリガーを確認"
