#!/bin/sh
# forgejo-token-rotate.sh — Forgejo (Git VM) の長期運用トークンをローテーション
#
# 背景: Forgejo (v15.0.3 時点) の CLI (`forgejo admin user generate-access-token`)
# にも REST API (`POST /users/{username}/tokens`) にも、トークンへ有効期限を
# 設定する機能が存在しない (アップストリームでも未実装の要望として残っている)。
# つまり vm-git/setup.sh が発行する BOT_TOKEN (owl-control.sh の sign-poll/
# deploy-poll が使用) と AUDIT_RELEASES_TOKEN (Audit VM の fohlen が使用) は、
# 手を打たない限り無期限に有効であり続ける。ネイティブな失効機能が無い以上、
# 「漏洩しても被害期間を有限にする」ための対策は定期的なローテーションしかない
# ため、本スクリプトを用意する。
#
# トークンの発行/一覧/失効は通常の "Authorization: token <値>" では行えず、
# `/users/{username}/tokens` エンドポイントは仕様上 Basic 認証 (ユーザー名+
# パスワード、2FA有効時は追加でワンタイムコード) を要求する。そのため本
# スクリプトは owlv-admin のパスワードを対話的に一度だけ尋ねる (画面には
# 表示しない・ファイルにも一切保存しない)。
#
# 【実行タイミング】運用者の判断で定期的に (推奨: 四半期に一度、または
# 要員異動・トークン漏洩の疑いが生じた際に都度)。
#
# 【このスクリプトが「やらないこと」】
#   - Audit VM (/provision/audit-releases-token) への新トークンの配布。
#     Audit VM は doc/dev_sec_ops.md §6.1/§6.3 により自身への SSH 受信を
#     恒久的に自己遮断しているため、ホストから push する経路が存在しない。
#     新しい監査用トークンは /etc/owlv/audit_releases_token に書き出すので、
#     Audit VM の再プロビジョニング (infra/vm-audit/setup.sh の再実行) の際に
#     配布すること。それまでは古い監査用トークンを残す (fohlen を無停止にする
#     ため、自動削除しない — 下記参照)。
set -eu

CONFIG=/etc/owlv/infra/owl-config.toml
BOT_TOKEN_FILE=/etc/owlv/forgejo_token
AUDIT_TOKEN_FILE=/etc/owlv/audit_releases_token

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_info() { _log "    $*"; }
_ok() { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root (doas) で実行してください"
[ -f "$CONFIG" ] || _die "$CONFIG が見つかりません"
command -v curl >/dev/null || _die "curl が必要です"
command -v openssl >/dev/null || _die "openssl が必要です"

_toml() {
	awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k { gsub(/^[^=]+=[ "]*|["]*$/,""); print; exit }
    ' "$CONFIG"
}

GIT_IP=$(_toml "network.dev_lan" "git_vm")
FORGEJO_OWNER=$(_toml "forgejo" "owner")
[ -n "$GIT_IP" ] && [ -n "$FORGEJO_OWNER" ] ||
	_die "owl-config.toml [network.dev_lan]/[forgejo] が不完全です"

API="http://${GIT_IP}:3000/api/v1"

# ── 認証情報の対話入力 (画面非表示・ファイル保存なし) ──────────
printf '%s の Forgejo パスワード: ' "$FORGEJO_OWNER" >&2
stty -echo 2>/dev/null || true
read -r ADMIN_PASS
stty echo 2>/dev/null || true
echo "" >&2
[ -n "$ADMIN_PASS" ] || _die "パスワードが空です"

printf '2FA コード (未設定なら空エンター): ' >&2
read -r ADMIN_OTP

BASIC_AUTH="$(printf '%s:%s' "$FORGEJO_OWNER" "$ADMIN_PASS" | openssl base64 -A)"
_curl_basic() {
	if [ -n "$ADMIN_OTP" ]; then
		curl -fsS -H "Authorization: Basic ${BASIC_AUTH}" -H "X-Forgejo-OTP: ${ADMIN_OTP}" "$@"
	else
		curl -fsS -H "Authorization: Basic ${BASIC_AUTH}" "$@"
	fi
}

# 発行直後にシェル変数として使い終えたら参照を切る (プロセス環境や後続の
# エラーメッセージに残さないため)。trap で異常終了時も確実にクリアする。
trap 'ADMIN_PASS=""; ADMIN_OTP=""' EXIT

_log "既存トークン一覧を取得中..."
EXISTING_JSON="$(_curl_basic "${API}/users/${FORGEJO_OWNER}/tokens?limit=50")" ||
	_die "トークン一覧の取得に失敗しました (パスワード/2FAコードを確認してください)"

# 超簡易 JSON 抽出 (id → name の出現順ペア)。owl-control.sh と同方針で
# jq 等の追加依存を避ける。
_extract_pairs() {
	printf '%s' "$1" | tr ',' '\n' | awk '
        /"id":/   { match($0,/"id":[0-9]+/); id=substr($0,RSTART+5,RLENGTH-5) }
        /"name":/ { match($0,/"name":"[^"]*"/); n=substr($0,RSTART+8,RLENGTH-9); print id "\t" n }
    '
}

OLD_PAIRS="$(_extract_pairs "$EXISTING_JSON")"

_create_token() {
	# $1 = トークン名  $2 = カンマ無しの scope 群 (JSON配列に自前で組む)
	_name="$1"
	shift
	_scopes_json=""
	for _s in "$@"; do
		[ -n "$_scopes_json" ] && _scopes_json="${_scopes_json},"
		_scopes_json="${_scopes_json}\"${_s}\""
	done
	_resp="$(_curl_basic -X POST -H "Content-Type: application/json" \
		-d "{\"name\":\"${_name}\",\"scopes\":[${_scopes_json}]}" \
		"${API}/users/${FORGEJO_OWNER}/tokens")" || _die "トークン発行に失敗しました (${_name})"
	printf '%s' "$_resp" | tr ',' '\n' | awk '
        /"sha1":/ { match($0,/"sha1":"[^"]*"/); print substr($0,RSTART+8,RLENGTH-9); exit }
    '
}

_delete_token() {
	# $1 = トークンID
	_curl_basic -X DELETE "${API}/users/${FORGEJO_OWNER}/tokens/$1" >/dev/null 2>&1 ||
		_info "警告: トークンID $1 の失効に失敗しました (手動確認してください)"
}

NEW_BOT_NAME="owlv-bot-$(date +%s)"
_log "新しい bot トークンを発行中 (${NEW_BOT_NAME})..."
NEW_BOT_TOKEN="$(_create_token "$NEW_BOT_NAME" write:repository write:user)"
[ -n "$NEW_BOT_TOKEN" ] || _die "bot トークンの発行に失敗しました (sha1 が空)"
umask 077
printf '%s' "$NEW_BOT_TOKEN" >"$BOT_TOKEN_FILE"
chmod 600 "$BOT_TOKEN_FILE"
_ok "bot トークン発行・${BOT_TOKEN_FILE} を更新"

NEW_AUDIT_NAME="owlv-audit-read-$(date +%s)"
_log "新しい Audit VM 用読み取り専用トークンを発行中 (${NEW_AUDIT_NAME})..."
NEW_AUDIT_TOKEN="$(_create_token "$NEW_AUDIT_NAME" read:repository)"
[ -n "$NEW_AUDIT_TOKEN" ] || _die "Audit VM 用トークンの発行に失敗しました (sha1 が空)"
printf '%s' "$NEW_AUDIT_TOKEN" >"$AUDIT_TOKEN_FILE"
chmod 600 "$AUDIT_TOKEN_FILE"
_ok "Audit VM 用トークン発行・${AUDIT_TOKEN_FILE} を更新 (Audit VM への配布は別途必要、下記参照)"

# 旧 bot トークンはホスト自身が唯一の利用者であり、上で即座に新トークンへ
# 差し替え済みのため、ここで安全に即時失効させる (漏洩時の有効期間を最小化)。
_log "旧 bot トークンを失効中..."
_deleted=0
printf '%s\n' "$OLD_PAIRS" | while IFS="$(printf '\t')" read -r _id _name; do
	[ -n "$_name" ] || continue
	case "$_name" in
	owlv-bot-*)
		_delete_token "$_id"
		_info "失効: ${_name} (id=${_id})"
		;;
	esac
done
_ok "旧 bot トークンの失効処理完了"

# 旧監査用トークンは自動失効させない (Audit VM 側の更新が別途手動作業のため、
# 先に失効させると更新完了までの間 fohlen の Forgejo API アクセスが壊れる)。
OLD_AUDIT_IDS="$(printf '%s\n' "$OLD_PAIRS" | awk -F'\t' '$2 ~ /^owlv-audit-read-/{print $1"\t"$2}')"

echo ""
echo "【ローテーション完了】"
echo "  新 bot トークン       : ${BOT_TOKEN_FILE} に保存済み (owl-control.sh が次回実行時から使用)"
echo "  新 Audit VM 用トークン: ${AUDIT_TOKEN_FILE} に保存済み"
echo ""
echo "【残っている手動作業】"
echo "  1. Audit VM への新トークン配布 (自動化できません — §6.1/§6.3 により"
echo "     ホストから Audit VM への恒久 SSH 経路が存在しないため):"
echo "     infra/vm-audit/setup.sh の再実行 (再プロビジョニング) 時に"
echo "     ${AUDIT_TOKEN_FILE} の内容を /provision/audit-releases-token として配置してください。"
if [ -n "$OLD_AUDIT_IDS" ]; then
	echo "  2. Audit VM 側の更新を確認した後、以下の旧トークンを Web UI または"
	echo "     API (DELETE ${API}/users/${FORGEJO_OWNER}/tokens/<id>) で失効させてください:"
	printf '%s\n' "$OLD_AUDIT_IDS" | while IFS="$(printf '\t')" read -r _id _name; do
		echo "       - ${_name} (id=${_id})"
	done
fi
echo ""
