#!/bin/sh
# owl-control.sh — owlv 運用制御スクリプト
# §2.1: ベースバックアップ  §2.2: DR 射出  §3: デプロイ
# 実行ユーザー: owl-control (cron) または wheel (手動)
# doas ルール: /etc/doas.conf 参照
set -eu

CONFIG=/etc/owlv/infra/owl-config.toml
KNOWN_HOSTS=/etc/owlv/known_hosts
BACKUP_KEY=/etc/owlv/backup_ed25519
# §4.2: リリース署名鍵はホストが排他的に保持する (Build VM には置かない)。
# 生成は host/steps/01-host-foundation.sh で行う。
SIGNIFY_SEC=/etc/owlv/release-signify.sec

LOCKFILE=/tmp/owl-dr.lock
LOGDIR=/var/log/owl
HOLD_FILE=/etc/owlv/INTEGRITY_HOLD
DEPLOYED_LOG=/etc/owlv/deployed_tags

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
FORGEJO_OWNER=$(_toml "forgejo" "owner")
FORGEJO_REPO=$(_toml "forgejo" "repo")
FORGEJO_TOKEN_FILE=$(_toml "forgejo" "api_token_file")

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
	cp /etc/owlv/infra/owl-config.toml "${WORK_DIR}/config/"
	cp /etc/owlv/integrity-baseline.sha256 "${WORK_DIR}/config/" 2>/dev/null || true

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
	DEST="/var/backup/owlv/basebackup/${SNAP_TS}"

	[ -f "$BACKUP_KEY" ] || _die "バックアップ SSH 鍵が未配置: ${BACKUP_KEY}"
	install -d "$DEST"

	_info "pg_basebackup → ${DEST}"
	_ssh "root@${DB_IP}" \
		"pg_basebackup -U ${DB_REPL} -D /tmp/owl-bb -Ft -Xs -P -c fast" \
		2>&1 | while read -r line; do _info "$line"; done
	_scp -rq "root@${DB_IP}:/tmp/owl-bb/." "${DEST}/"
	_ssh "root@${DB_IP}" "rm -rf /tmp/owl-bb"

	# 30日超のバックアップを削除 (§2.1 保持ポリシー)
	find /var/backup/owlv/basebackup/ -maxdepth 1 -type d -mtime +30 \
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

	# AP VM 上で 三重検証(signify 署名 / uname -r 一致 / SHA256 一致、§4.2)を
	# 行ったうえでバージョン固有名に配置し、シンボリックリンクをアトミックに
	# 切り替える。owlv-app / owlv-batch-center / owlv-projector の3バイナリを
	# 同一タグから一括デプロイし、デプロイ経路を1本に統一する。
	# owlv-app は owl-session 経由の per-SSH 起動 (rc.d サービスではない) なので
	# rcctl restart owlv は対象サービスが無く無害に失敗する (2>/dev/null || true)。
	# owlv-batch-center は cron 起動のみで常駐しないため再起動は不要。
	# owlv-projector は rcctl 管理の常駐デーモンなので実際に再起動・起動確認を行い、
	# 失敗時は旧バイナリへ即時ロールバックする (doc/cqrs.md, doc/dev_sec_ops.md §4.2)。
	# ローカル変数は env 経由で渡し、リモート側スクリプトはシングルクォートの
	# ヒアドキュメントにして二重のエスケープを避ける。
	_info "AP VM (${AP_IP}) にデプロイ"
	_ssh "root@${AP_IP}" \
		"env TAG='${TAG}' GIT_IP='${GIT_IP}' OWNER='${FORGEJO_OWNER}' REPO='${FORGEJO_REPO}' sh -s" <<'REMOTE'
set -eu

TMP="$(mktemp -d /tmp/owlv-deploy.XXXXXX)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cd "$TMP"
BASE_URL="http://${GIT_IP}:3000/${OWNER}/${REPO}/releases/download/${TAG}"
for f in owlv-app-openbsd-amd64 owlv-batch-center-openbsd-amd64 owlv-projector-openbsd-amd64 \
    manifest.txt manifest.txt.sig; do
	ftp -o "$f" "${BASE_URL}/${f}"
done

[ -f /etc/owlv/release-signify.pub ] ||
	{ echo "release-signify.pub が未配置です: /etc/owlv/release-signify.pub" >&2; exit 1; }
signify -V -p /etc/owlv/release-signify.pub -m manifest.txt -x manifest.txt.sig ||
	{ echo "manifest.txt の signify 署名検証に失敗しました" >&2; exit 1; }

UNAME_R_LOCAL="$(uname -r)"
UNAME_R_EXPECTED="$(awk -F= '/^uname_r=/{print $2}' manifest.txt)"
[ "$UNAME_R_LOCAL" = "$UNAME_R_EXPECTED" ] ||
	{ echo "OS リリース不一致: 本機 ${UNAME_R_LOCAL} / ビルド時 ${UNAME_R_EXPECTED}" >&2; exit 1; }

for pair in owlv-app-openbsd-amd64:owlv-app owlv-batch-center-openbsd-amd64:owlv-batch-center \
    owlv-projector-openbsd-amd64:owlv-projector; do
	src="${pair%%:*}"
	base="${pair##*:}"
	expected="$(awk -F= -v k="${src}.sha256" '$1==k{print $2}' manifest.txt)"
	[ -n "$expected" ] || { echo "manifest.txt に ${src} のハッシュがありません" >&2; exit 1; }
	actual="$(sha256 -q "$src")"
	[ "$expected" = "$actual" ] || { echo "SHA256 不一致: ${src}" >&2; exit 1; }
	chmod 755 "$src"
	cp "$src" "/usr/local/bin/${base}_${TAG}"
done

# シンボリックリンクの切替はリンク作成 → 同名へ mv (同一ファイルシステム内の
# rename はアトミック) という手順にし、旧リンクが一瞬でも存在しない状態を作らない。
ln -sf "owlv-app_${TAG}" /usr/local/bin/owlv-app.new
mv /usr/local/bin/owlv-app.new /usr/local/bin/owlv-app
ln -sf "owlv-batch-center_${TAG}" /usr/local/bin/owlv-batch-center.new
mv /usr/local/bin/owlv-batch-center.new /usr/local/bin/owlv-batch-center

PREV_PROJECTOR="$(readlink /usr/local/bin/owlv-projector 2>/dev/null || true)"
ln -sf "owlv-projector_${TAG}" /usr/local/bin/owlv-projector.new
mv /usr/local/bin/owlv-projector.new /usr/local/bin/owlv-projector

rcctl restart owlv_projector
sleep 1
if ! rcctl check owlv_projector >/dev/null 2>&1; then
	echo "新 owlv-projector の起動に失敗。旧バイナリへロールバックします" >&2
	if [ -n "$PREV_PROJECTOR" ]; then
		ln -sf "$PREV_PROJECTOR" /usr/local/bin/owlv-projector.new
		mv /usr/local/bin/owlv-projector.new /usr/local/bin/owlv-projector
		rcctl restart owlv_projector
	fi
	exit 1
fi

rcctl restart owlv 2>/dev/null || true
REMOTE

	_log "デプロイ完了: ${TAG}"
}

# ────────────────────────────────────────────────────────────
# コマンド: sign-poll
# §4.2: Build VM の CI (vm-git/build.yml) が draft=true で作成した「未署名」
# リリースを検知し、ホストが排他的に保持する signify 秘密鍵で manifest.txt に
# 署名する。署名鍵を Build VM に置かないのは、Build VM が push/PR という外部
# 入力を直接処理し攻撃面が最も広いため — ここに鍵を置くと Build VM 侵害時に
# 攻撃者が改ざんバイナリへ正規の署名を付与できてしまい、「成果物改ざんは署名
# 検証で検出される」という前提(信頼の根)が崩壊する。署名後に draft=false へ
# 切り替えることで「承認済み・未デプロイ」状態とし、deploy-poll の検知対象にする。
# ────────────────────────────────────────────────────────────
cmd_sign_poll() {
	_lock
	trap '_unlock' EXIT
	_check_hold

	[ -f "$SIGNIFY_SEC" ] || _die "署名鍵が未配置です: ${SIGNIFY_SEC}"
	[ -f "$FORGEJO_TOKEN_FILE" ] || _die "Forgejo API トークンが未配置: ${FORGEJO_TOKEN_FILE}"
	TOKEN="$(cat "$FORGEJO_TOKEN_FILE")"
	GIT_IP=$(_toml "network.dev_lan" "git_vm")

	RELEASES_JSON="$(curl -fsS \
		-H "Authorization: token ${TOKEN}" \
		"http://${GIT_IP}:3000/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/releases?draft=true&limit=20")" ||
		_die "Forgejo API への接続に失敗しました"

	PAIRS="$(printf '%s' "$RELEASES_JSON" | tr ',' '\n' | awk '
        /"id":/       { match($0, /"id":[0-9]+/); id = substr($0, RSTART + 5, RLENGTH - 5) }
        /"tag_name":/ { match($0, /"tag_name":"[^"]*"/); t = substr($0, RSTART + 12, RLENGTH - 14); print id "\t" t }
    ')"

	if [ -z "$PAIRS" ]; then
		_info "未署名 (draft) のリリースはありません"
		_unlock
		trap - EXIT
		return 0
	fi

	printf '%s\n' "$PAIRS" | while IFS="$(printf '\t')" read -r rel_id tag; do
		[ -n "$tag" ] || continue

		_info "未署名リリースを検知: ${tag}"
		TMP="$(mktemp -d /tmp/owl-sign.XXXXXX)"

		if ! curl -fsS -o "${TMP}/manifest.txt" \
			"http://${GIT_IP}:3000/${FORGEJO_OWNER}/${FORGEJO_REPO}/releases/download/${tag}/manifest.txt"; then
			_info "警告: ${tag} の manifest.txt 取得に失敗。スキップします"
			rm -rf "$TMP"
			continue
		fi

		if ! signify -S -s "$SIGNIFY_SEC" -m "${TMP}/manifest.txt" -x "${TMP}/manifest.txt.sig"; then
			_info "警告: ${tag} の署名に失敗。スキップします"
			rm -rf "$TMP"
			continue
		fi

		if ! curl -fsS -X POST \
			-H "Authorization: token ${TOKEN}" \
			-F "attachment=@${TMP}/manifest.txt.sig" \
			"http://${GIT_IP}:3000/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/releases/${rel_id}/assets?name=manifest.txt.sig" >/dev/null; then
			_info "警告: ${tag} の manifest.txt.sig 添付に失敗。スキップします"
			rm -rf "$TMP"
			continue
		fi

		if ! curl -fsS -X PATCH \
			-H "Authorization: token ${TOKEN}" \
			-H "Content-Type: application/json" \
			-d '{"draft":false}' \
			"http://${GIT_IP}:3000/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/releases/${rel_id}" >/dev/null; then
			_info "警告: ${tag} の draft 解除に失敗しました(署名は完了済み。手動で確認してください)"
			rm -rf "$TMP"
			continue
		fi

		rm -rf "$TMP"
		_info "署名完了・公開: ${tag}"
	done

	_unlock
	trap - EXIT
}

# ────────────────────────────────────────────────────────────
# コマンド: deploy-poll
# §4.2: PR の Approve & Merge をトリガに Forgejo Runner が自動生成した
# 「承認済み」リリースを定期照会し、未デプロイのものを検知したら deploy する。
# internal_lan からの着信(webhook 等)は一切受け付けず、検知は常にこのホスト発の
# ポーリングに限る(§1.1.1)。宛先(Git VM)は固定内部IPのため、ピンホールではなく
# pf.conf の恒久ルールで到達する。
# ────────────────────────────────────────────────────────────
cmd_deploy_poll() {
	_lock
	trap '_unlock' EXIT
	_check_hold

	[ -f "$FORGEJO_TOKEN_FILE" ] || _die "Forgejo API トークンが未配置: ${FORGEJO_TOKEN_FILE}"
	TOKEN="$(cat "$FORGEJO_TOKEN_FILE")"
	GIT_IP=$(_toml "network.dev_lan" "git_vm")
	touch "$DEPLOYED_LOG"

	RELEASES_JSON="$(curl -fsS \
		-H "Authorization: token ${TOKEN}" \
		"http://${GIT_IP}:3000/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/releases?draft=false&pre-release=false&limit=20")" ||
		_die "Forgejo API への接続に失敗しました"

	# 超簡易 JSON 抽出 (id → tag_name の出現順ペア)。jq 等の追加依存を避け、
	# Forgejo が返すフィールド順を前提とする割り切り (owl-user-sync と同方針)。
	PAIRS="$(printf '%s' "$RELEASES_JSON" | tr ',' '\n' | awk '
        /"id":/       { match($0, /"id":[0-9]+/); id = substr($0, RSTART + 5, RLENGTH - 5) }
        /"tag_name":/ { match($0, /"tag_name":"[^"]*"/); t = substr($0, RSTART + 12, RLENGTH - 14); print id "\t" t }
    ')"

	if [ -z "$PAIRS" ]; then
		_info "承認済み未デプロイのリリースはありません"
		_unlock
		trap - EXIT
		return 0
	fi

	printf '%s\n' "$PAIRS" | while IFS="$(printf '\t')" read -r rel_id tag; do
		[ -n "$tag" ] || continue
		grep -qxF "$tag" "$DEPLOYED_LOG" 2>/dev/null && continue

		_info "未デプロイの承認済みリリースを検知: ${tag}"
		cmd_deploy "$tag"
		echo "$tag" >>"$DEPLOYED_LOG"

		# Forgejo 側にも書き戻し、承認(Approve)からデプロイ完了までを
		# Web UI 上で不変ログとして追跡可能にする(§4.2)。失敗してもデプロイ
		# 自体は完了しているため、警告のみでポーリングは継続する。
		curl -fsS -X PATCH \
			-H "Authorization: token ${TOKEN}" \
			-H "Content-Type: application/json" \
			-d "{\"name\":\"${tag} [deployed $(date -u +%FT%TZ)]\"}" \
			"http://${GIT_IP}:3000/api/v1/repos/${FORGEJO_OWNER}/${FORGEJO_REPO}/releases/${rel_id}" >/dev/null ||
			_info "警告: Forgejo へのデプロイ済みマーク書き込みに失敗しました(デプロイ自体は完了)"
	done

	_unlock
	trap - EXIT
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
	ls -t /var/backup/owlv/basebackup/ 2>/dev/null | head -3 |
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
sign-poll) cmd_sign_poll ;;
deploy-poll) cmd_deploy_poll ;;
status) cmd_status ;;
*)
	echo "usage: owl-control.sh <command>" >&2
	echo "  dr-export          — DR アーカイブを生成してクラウドに送出" >&2
	echo "  basebackup         — pg_basebackup をローカルに保存" >&2
	echo "  deploy <tag>       — owlv バイナリを AP VM にデプロイ" >&2
	echo "  sign-poll          — 未署名(draft)のリリースを検知してホスト鍵で署名" >&2
	echo "  deploy-poll        — 承認済み未デプロイのリリースを検知して自動デプロイ" >&2
	echo "  status             — VM / DB の稼働状態を確認" >&2
	exit 1
	;;
esac
