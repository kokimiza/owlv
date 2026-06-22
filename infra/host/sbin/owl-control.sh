#!/bin/sh
# owl-control.sh — owlv 運用制御スクリプト
# §2.1: ベースバックアップ  §2.2: DR 射出  §3: デプロイ
# 実行ユーザー: owl-control (cron) または wheel (手動)
# doas ルール: /etc/doas.conf 参照
set -eu

CONFIG=/etc/owl/infra/owl-config.toml
KNOWN_HOSTS=/etc/owl/known_hosts
BACKUP_KEY=/etc/owl/backup_ed25519

LOCKFILE=/tmp/owl-dr.lock
LOGDIR=/var/log/owl
HOLD_FILE=/etc/owl/INTEGRITY_HOLD

# ── TOML 読み込み ───────────────────────────────────────────
_toml() {
	awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k { gsub(/^[^=]+=[ "]*|["]*$/,""); print; exit }
    ' "$CONFIG"
}

DB_IP=$(_toml "network.internal_lan" "db_vm")
AP_IP=$(_toml "network.internal_lan" "ap_vm")
RAMDISK=$(_toml "dr" "ramdisk_mount")
AGE_PUB=$(_toml "dr" "age_pubkey_file")
B2_REMOTE=$(_toml "dr" "b2_remote")
RSYNC_REMOTE=$(_toml "dr" "rsyncnet_remote")
WINDOW=$(_toml "dr" "window_seconds")
PG_VER=$(_toml "app" "pg_version")
DB_NAME=$(_toml "app" "db_name")
DB_REPL=$(_toml "app" "db_repl_user")

# ── ヘルパー ────────────────────────────────────────────────
_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_info() { _log "    $*"; }

# StrictHostKeyChecking=yes で known_hosts を固定 (MITM 対策)
_ssh() {
	ssh -i "$BACKUP_KEY" \
		-o StrictHostKeyChecking=yes \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o BatchMode=yes \
		-o ConnectTimeout=10 \
		"$@"
}

_scp() {
	scp -i "$BACKUP_KEY" \
		-o StrictHostKeyChecking=yes \
		-o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o BatchMode=yes \
		"$@"
}

# ── 排他ロック (シンボリックリンクはアトミック) ─────────────
_lock() {
	ln -s "$$" "$LOCKFILE" 2>/dev/null || {
		holder="$(readlink "$LOCKFILE" 2>/dev/null || echo '?')"
		_die "別の owl-control プロセス (PID ${holder}) が実行中"
	}
	trap '_unlock; exit 1' INT TERM HUP
}

_unlock() {
	rm -f "$LOCKFILE"
}

# ── 改ざん保留確認 (§5) ────────────────────────────────────
_check_hold() {
	if [ -f "$HOLD_FILE" ]; then
		_die "INTEGRITY_HOLD が設定されています。手動確認後に削除してください: ${HOLD_FILE}"
	fi
}

# ── ピンホール制御 ─────────────────────────────────────────
_pinhole_open() {
	doas /usr/local/sbin/owl-pfctl-pinhole open "$@"
	_info "ピンホール開放 ($*) — ${WINDOW}秒後に自動閉鎖"
	sleep "$WINDOW" && doas /usr/local/sbin/owl-pfctl-pinhole close &
	_PINHOLE_TIMER_PID=$!
}

_pinhole_close() {
	doas /usr/local/sbin/owl-pfctl-pinhole close
	[ -n "${_PINHOLE_TIMER_PID:-}" ] && kill "$_PINHOLE_TIMER_PID" 2>/dev/null || true
	_PINHOLE_TIMER_PID=""
}

# ── RAM ディスク クリーンアップ ───────────────────────────
_cleanup_dr() {
	if mount | grep -q "^mfs .* ${RAMDISK}"; then
		_info "RAM ディスクをゼロ埋めして解放します"
		# 機密データがスワップに漏れないようにゼロ埋め
		find "$RAMDISK" -type f -exec sh -c \
			'dd if=/dev/zero of="$1" bs=4096 2>/dev/null; rm -f "$1"' _ {} \;
		umount "$RAMDISK" || true
	fi
}

# ────────────────────────────────────────────────────────────
# コマンド: dr-export
# §2.2: DB スナップショット → age 暗号化 → B2 + rsync.net 二重アップロード
# ────────────────────────────────────────────────────────────
cmd_dr_export() {
	_log "DR 射出開始"
	_lock
	_check_hold

	[ -f "$AGE_PUB" ] || _die "age 受信者公開鍵が未配置: ${AGE_PUB}"
	[ -f "$BACKUP_KEY" ] || _die "バックアップ SSH 鍵が未配置: ${BACKUP_KEY}"

	SNAP_TS="$(date +%Y%m%d_%H%M%S)"
	ARCHIVE_NAME="owl-dr-${SNAP_TS}.tar.gz.age"
	WORK_DIR="${RAMDISK}/work"

	# RAM ディスクをマウント (32MB で十分 — WAL + config のみ)
	install -d "$RAMDISK"
	if ! mount | grep -q "^mfs .* ${RAMDISK}"; then
		mount -t mfs -o size=64m mfs "$RAMDISK"
	fi
	install -d "$WORK_DIR"
	trap '_cleanup_dr; _unlock' EXIT

	# DB VM からWAL アーカイブ取得
	_info "DB VM からWAL スナップショット取得"
	_ssh "root@${DB_IP}" \
		"pg_basebackup -U ${DB_REPL} -D /tmp/owl-snapshot -Ft -Xs -P -c fast" \
		2>&1 | while read -r line; do _info "$line"; done
	_scp -rq "root@${DB_IP}:/tmp/owl-snapshot/." "${WORK_DIR}/db/"
	_ssh "root@${DB_IP}" "rm -rf /tmp/owl-snapshot"

	# 設定ファイルのスナップショット
	_info "設定スナップショット"
	install -d "${WORK_DIR}/config"
	cp /etc/owl/infra/owl-config.toml "${WORK_DIR}/config/"
	cp /etc/owl/integrity-baseline.sha256 "${WORK_DIR}/config/" 2>/dev/null || true

	# tar + age 暗号化
	_info "圧縮・暗号化"
	tar -czf - -C "$WORK_DIR" . |
		age -r "$(cat "$AGE_PUB")" \
			>"${RAMDISK}/${ARCHIVE_NAME}"

	# ピンホール開放 → クラウドアップロード → 閉鎖
	# rclone が接続する B2 / rsync.net の IP を resolve して渡す
	B2_IPS="$(host b2.backblazeb2.com 2>/dev/null | awk '/has address/{print $4}' | head -3 | tr '\n' ' ')"
	RN_IPS="$(host usw-s1.rsync.net 2>/dev/null | awk '/has address/{print $4}' | head -3 | tr '\n' ' ')"

	_info "クラウドへアップロード"
	# shellcheck disable=SC2086
	_pinhole_open $B2_IPS $RN_IPS

	rclone copy "${RAMDISK}/${ARCHIVE_NAME}" "${B2_REMOTE}/" \
		--no-traverse --progress 2>&1 | while read -r line; do _info "B2: $line"; done

	rclone copy "${RAMDISK}/${ARCHIVE_NAME}" "${RSYNC_REMOTE}/" \
		--no-traverse --progress 2>&1 | while read -r line; do _info "rsync.net: $line"; done

	_pinhole_close

	_cleanup_dr
	_unlock
	trap - EXIT
	_log "DR 射出完了: ${ARCHIVE_NAME}"
}

# ────────────────────────────────────────────────────────────
# コマンド: basebackup
# §2.1 L1: pg_basebackup による週次フルバックアップ → ローカル保存
# ────────────────────────────────────────────────────────────
cmd_basebackup() {
	_log "ベースバックアップ開始"
	_lock
	_check_hold

	SNAP_TS="$(date +%Y%m%d_%H%M%S)"
	DEST="/var/backup/owl/basebackup/${SNAP_TS}"

	[ -f "$BACKUP_KEY" ] || _die "バックアップ SSH 鍵が未配置: ${BACKUP_KEY}"
	install -d "$DEST"

	_info "pg_basebackup → ${DEST}"
	_ssh "root@${DB_IP}" \
		"pg_basebackup -U ${DB_REPL} -D /tmp/owl-bb -Ft -Xs -P -c fast" \
		2>&1 | while read -r line; do _info "$line"; done
	_scp -rq "root@${DB_IP}:/tmp/owl-bb/." "${DEST}/"
	_ssh "root@${DB_IP}" "rm -rf /tmp/owl-bb"

	# 30日超のバックアップを削除 (§2.1 保持ポリシー)
	find /var/backup/owl/basebackup/ -maxdepth 1 -type d -mtime +30 \
		-exec rm -rf {} + 2>/dev/null || true

	_unlock
	trap - EXIT
	_log "ベースバックアップ完了: ${DEST}"
}

# ────────────────────────────────────────────────────────────
# コマンド: deploy <tag>
# §3.1: Forgejo パッケージレジストリから owlv バイナリを AP VM にデプロイ
# ────────────────────────────────────────────────────────────
cmd_deploy() {
	TAG="${1:-}"
	[ -n "$TAG" ] || _die "タグを指定してください: deploy <vX.Y.Z>"
	_log "デプロイ開始: ${TAG}"

	GIT_IP=$(_toml "network.dev_lan" "git_vm")
	FORGEJO_VER=$(_toml "forgejo" "version")

	OWNER="owl"
	REPO="owlv"

	# AP VM にバイナリをダウンロードして入れ替え (アトミック mv)。owlv-app /
	# owlv-batch-center / owlv-projector の3バイナリを同一タグから一括デプロイし、
	# デプロイ経路を1本に統一する (旧来 owlv-batch-center は cron_batch.md §8 の
	# signify検証版 owlv-deploy-batch が想定されていたが、CIの署名生成パイプライン
	# 自体がまだ存在しないため、署名検証だけ実装しても検証対象が無く意味がない。
	# CI署名パイプライン整備後に両立/置き換えを再検討すること)。
	# owlv-app は owl-session 経由の per-SSH 起動 (rc.d サービスではない) なので
	# rcctl restart owlv は対象サービスが無く無害に失敗する (2>/dev/null || true)。
	# owlv-batch-center は cron 起動のみで常駐しないため再起動は不要。
	# owlv-projector は rcctl 管理の常駐デーモン (doc/cqrs.md) なので実際に再起動が効く。
	_info "AP VM (${AP_IP}) にデプロイ"
	_ssh "root@${AP_IP}" "
        set -e
        ftp -o /tmp/owlv-app-new           'http://${GIT_IP}:3000/${OWNER}/${REPO}/releases/download/${TAG}/owlv-app-openbsd-amd64'
        ftp -o /tmp/owlv-batch-center-new  'http://${GIT_IP}:3000/${OWNER}/${REPO}/releases/download/${TAG}/owlv-batch-center-openbsd-amd64'
        ftp -o /tmp/owlv-projector-new     'http://${GIT_IP}:3000/${OWNER}/${REPO}/releases/download/${TAG}/owlv-projector-openbsd-amd64'
        chmod 755 /tmp/owlv-app-new /tmp/owlv-batch-center-new /tmp/owlv-projector-new
        mv /tmp/owlv-app-new /usr/local/bin/owlv-app
        mv /tmp/owlv-batch-center-new /usr/local/bin/owlv-batch-center
        mv /tmp/owlv-projector-new /usr/local/bin/owlv-projector
        rcctl restart owlv 2>/dev/null || true
        rcctl restart owlv_projector
    "

	_log "デプロイ完了: ${TAG}"
}

# ────────────────────────────────────────────────────────────
# コマンド: status
# ────────────────────────────────────────────────────────────
cmd_status() {
	echo "=== owlv 運用状態 ==="
	echo ""

	echo "--- ホスト VM ---"
	for vm in vm-ap vm-db vm-git vm-build; do
		st="$(vmctl status "$vm" 2>&1 | awk 'NR==2{print $NF}')"
		printf '  %-12s %s\n' "$vm" "${st:-unknown}"
	done
	echo ""

	echo "--- DB VM (${DB_IP}) ---"
	_ssh "root@${DB_IP}" \
		"psql -U postgres -c '\\l' 2>/dev/null || echo 'PostgreSQL 未応答'" 2>/dev/null ||
		echo "  SSH 未応答"
	echo ""

	echo "--- INTEGRITY_HOLD ---"
	if [ -f "$HOLD_FILE" ]; then
		echo "  有効 (設定: $(cat "$HOLD_FILE"))"
	else
		echo "  なし"
	fi
	echo ""

	echo "--- 直近のバックアップ ---"
	ls -t /var/backup/owl/basebackup/ 2>/dev/null | head -3 |
		while read -r d; do echo "  $d"; done || echo "  なし"
}

# ────────────────────────────────────────────────────────────
# エントリーポイント
# ────────────────────────────────────────────────────────────
case "${1:-}" in
dr-export) cmd_dr_export ;;
basebackup) cmd_basebackup ;;
deploy)
	shift
	cmd_deploy "$@"
	;;
status) cmd_status ;;
*)
	echo "usage: owl-control.sh <command>" >&2
	echo "  dr-export          — DR アーカイブを生成してクラウドに送出" >&2
	echo "  basebackup         — pg_basebackup をローカルに保存" >&2
	echo "  deploy <tag>       — owlv バイナリを AP VM にデプロイ" >&2
	echo "  status             — VM / DB の稼働状態を確認" >&2
	exit 1
	;;
esac
