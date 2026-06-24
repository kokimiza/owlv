#!/bin/sh
# owl-integrity-check.sh — 改ざん検知スクリプト (§5)
# 毎日 02:30 に root の cron から実行される
# 差分があれば /etc/owlv/INTEGRITY_HOLD を作成して自動 DR 射出を停止する
set -eu

BASELINE=/etc/owlv/integrity-baseline.sha256
HOLD_FILE=/etc/owlv/INTEGRITY_HOLD
LOGDIR=/var/log/owlv
# POSIX sh では ${$(date ...)} は無効。必ず別行で代入する
DIFF_TS="$(date +%Y%m%d_%H%M%S)"
DIFF_FILE="${LOGDIR}/integrity-diff-${DIFF_TS}.txt"

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [ ! -f "$BASELINE" ]; then
	_log "ベースライン未作成: ${BASELINE}。provision.sh を先に実行してください。" >&2
	exit 1
fi

_log "改ざん検知チェック開始"

# 現在のハッシュを計算 (ベースラインと同一の対象)
CURRENT="$(mktemp /tmp/owl-integrity.XXXXXX)"
trap 'rm -f "$CURRENT"' EXIT

find /etc /usr/local/sbin -type f 2>/dev/null | sort |
	xargs sha256 >"$CURRENT"

if diff -u "$BASELINE" "$CURRENT" >"$DIFF_FILE" 2>&1; then
	_log "改ざんなし"
	rm -f "$DIFF_FILE"
	exit 0
fi

_log "警告: ファイル変更を検出しました。差分: ${DIFF_FILE}"

# INTEGRITY_HOLD を立てて自動 DR 射出を停止する
if [ ! -f "$HOLD_FILE" ]; then
	printf 'integrity-diff: %s\n' "$DIFF_FILE" >"$HOLD_FILE"
	_log "INTEGRITY_HOLD を設定しました"
	_log "確認後に手動で削除: rm ${HOLD_FILE}"
fi

# 管理者へのアラート (syslog 経由)
logger -p auth.warning -t owl-integrity \
	"改ざん検出: diff=${DIFF_FILE} — 確認後に INTEGRITY_HOLD を解除してください"

exit 2
