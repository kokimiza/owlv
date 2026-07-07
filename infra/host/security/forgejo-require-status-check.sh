#!/bin/sh
# forgejo-require-status-check.sh — ブランチ保護に必須ステータスチェックの
# コンテキストを追加設定する
#
# 背景 (doc/dev_sec_ops.md §3.3): vm-git/setup.sh がプロビジョニング時に作る
# main/dev のブランチ保護は enable_status_check:true のみを設定しており、
# status_check_contexts (「どの CI ジョブの成功を必須とするか」) を空のまま
# にしている。これは手抜きではなく技術的制約: Forgejo Actions が実際に
# 報告するコンテキスト名 (例: "build / build (pull_request)") は、そのブランチ
# 向けの CI が一度も走っていないプロビジョニング時点では存在しないため、
# vm-git/setup.sh からは正確な値を知りようがない。空のまま(=何を必須とする
# か指定なし)だと、CI がどんな結果を返してもマージ自体は妨げられない可能性が
# 高く、「main 宛 PR は dev からのみ」という担保が事実上 build.yml 内の
# チェックステップ1箇所だけに依存する単一障害点になる (Runner 侵害や
# ワークフロー改変で無効化され得る)。
#
# 【実行タイミング】対象ブランチ向けの CI (build.yml) が最低1回成功した後。
#
# 【コンテキスト名の調べ方】
#   Forgejo Web UI → リポジトリ設定 → ブランチ → 対象ブランチの保護設定を
#   開くと、「ステータスチェック」欄に直近報告されたコンテキスト名が
#   一覧表示される。それをそのままこのスクリプトの第2引数に渡すこと
#   (推測で値を決め打ちしない — 一致しない文字列を指定すると、必須チェックが
#   永遠に満たされずマージが止まったままになる)。
#
# 使い方:
#   doas sh forgejo-require-status-check.sh <branch> <context>
#   例: doas sh forgejo-require-status-check.sh main 'build / build (pull_request)'
#
# 既存のブランチ保護設定 (approve数・push可否等) には触れない
# (PATCH で status_check_contexts フィールドのみ更新)。
set -eu

CONFIG=/etc/owlv/infra/owl-config.toml

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_ok() { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root (doas) で実行してください"
[ -f "$CONFIG" ] || _die "$CONFIG が見つかりません"

_toml() {
	awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k { gsub(/^[^=]+=[ "]*|["]*$/,""); print; exit }
    ' "$CONFIG"
}

BRANCH="${1:-}"
CONTEXT="${2:-}"
[ -n "$BRANCH" ] && [ -n "$CONTEXT" ] ||
	_die "使い方: forgejo-require-status-check.sh <branch> <context>"

case "$CONTEXT" in
*'"'* | *'\'*) _die "context に \" や \\ は使用できません: ${CONTEXT}" ;;
esac

GIT_IP=$(_toml "network.dev_lan" "git_vm")
FORGEJO_OWNER=$(_toml "forgejo" "owner")
FORGEJO_REPO=$(_toml "forgejo" "repo")
FORGEJO_TOKEN_FILE=$(_toml "forgejo" "api_token_file")

[ -n "$GIT_IP" ] && [ -n "$FORGEJO_OWNER" ] && [ -n "$FORGEJO_REPO" ] ||
	_die "owl-config.toml [forgejo]/[network.dev_lan] が不完全です"
[ -f "$FORGEJO_TOKEN_FILE" ] || _die "Forgejo API トークンが未配置: ${FORGEJO_TOKEN_FILE}"
TOKEN="$(cat "$FORGEJO_TOKEN_FILE")"

API="http://${GIT_IP}:3000/api/v1"

_log "${BRANCH} の必須ステータスチェックを設定: ${CONTEXT}"
_BODY="$(mktemp)"
_STATUS=$(curl -s -o "$_BODY" -w '%{http_code}' -X PATCH \
	-H "Authorization: token ${TOKEN}" \
	-H "Content-Type: application/json" \
	-d "{\"enable_status_check\":true,\"status_check_contexts\":[\"${CONTEXT}\"]}" \
	"${API}/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/branch_protections/${BRANCH}")

case "$_STATUS" in
2??)
	_ok "${BRANCH} のブランチ保護を更新 (status_check_contexts=[\"${CONTEXT}\"])"
	;;
*)
	_log "ブランチ保護更新 API 応答 (status=${_STATUS}):"
	while IFS= read -r l || [ -n "$l" ]; do _log "    $l"; done <"$_BODY"
	rm -f "$_BODY"
	_die "${BRANCH} のブランチ保護更新に失敗しました (status=${_STATUS})"
	;;
esac
rm -f "$_BODY"

echo ""
echo "確認: Web UI (リポジトリ設定 → ブランチ) で ${BRANCH} の保護設定を開き、"
echo "「ステータスチェック」に ${CONTEXT} が必須として表示されていることを確認してください。"
echo "設定直後に試験用の PR を1つ通し、CI 成功でマージ可能・CI 失敗でマージ不可になることも確認すること。"
