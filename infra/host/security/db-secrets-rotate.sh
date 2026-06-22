#!/bin/sh
# db-secrets-rotate.sh — DB VM の初期パスワードをローテーションし AP VM に伝播
#
# vm-db/setup.sh は postgres / owl_app / owl_repl に固定の仮パスワード
# (changeme_*) を設定する (DB が外部から到達不能な内部 LAN にある間の
# 一時値)。本番運用前に強パスワードへ差し替え、AP VM の db.env にも
# 反映する必要があるが、これを provision.sh に組み込むと:
#   - パスワードがログ (/var/log/owl/provision-*.log) に残ってしまう
#   - VM 起動直後 (まだ疎通確認中) にやる処理ではない
# ので host/security/ に分離している。
#
# 【実行タイミング】STEP 9 (本番封鎖) 完了後、一度だけ。
#
# 【このスクリプトが「やらないこと」】
#   - TLS 証明書の本番差し替え (vm-db/ssl/PLACEHOLDER 参照) — 内部 CA 発行の
#     証明書という外部材料が必要なため、ここでは自動化できない
#   - owlv スキーマの適用 — infra/vm-db/schema.sql がまだ存在しない場合は
#     スキップしてその旨を表示する
set -eu

CONFIG=/etc/owl/infra/owl-config.toml
KNOWN_HOSTS=/etc/owl/known_hosts
BACKUP_KEY=/etc/owl/backup_ed25519
INFRA_ROOT=/etc/owl/infra

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

DB_IP=$(_toml "network.internal_lan" "db_vm")
AP_IP=$(_toml "network.internal_lan" "ap_vm")
DB_NAME=$(_toml "app" "db_name")
DB_APP_USER=$(_toml "app" "db_app_user")
DB_REPL_USER=$(_toml "app" "db_repl_user")
DB_MIGRATOR_USER=$(_toml "app" "db_migrator_user")
DB_PLATFORM_ADMIN_USER=$(_toml "app" "db_platform_admin_user")
DB_PROJECTOR_USER=$(_toml "app" "db_projector_user")

[ -n "$DB_IP" ] && [ -n "$AP_IP" ] || _die "owl-config.toml [network.internal_lan] が不完全です"

_ssh_db() {
	ssh -i "$BACKUP_KEY" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o BatchMode=yes -o ConnectTimeout=10 "root@${DB_IP}" "$@"
}
_ssh_ap() {
	ssh -i "$BACKUP_KEY" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o BatchMode=yes -o ConnectTimeout=10 "root@${AP_IP}" "$@"
}
_scp_from_db() {
	scp -i "$BACKUP_KEY" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o BatchMode=yes "root@${DB_IP}:$1" "$2"
}
_scp_to_ap() {
	scp -i "$BACKUP_KEY" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
		-o BatchMode=yes "$1" "root@${AP_IP}:$2"
}

PG_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)
APP_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)
REPL_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)
MIGRATOR_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)
PLATFORM_ADMIN_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)
PROJECTOR_PASS=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)

_log "DB VM (${DB_IP}) のパスワードをローテーションします"

_ssh_db "su -m _postgresql -c \"psql -c \\\"ALTER USER postgres PASSWORD '${PG_PASS}';\\\"\"" ||
	_die "postgres のパスワード変更に失敗しました"
_ssh_db "su -m _postgresql -c \"psql -c \\\"ALTER USER ${DB_APP_USER} PASSWORD '${APP_PASS}';\\\"\"" ||
	_die "${DB_APP_USER} のパスワード変更に失敗しました"
_ssh_db "su -m _postgresql -c \"psql -c \\\"ALTER USER ${DB_REPL_USER} PASSWORD '${REPL_PASS}';\\\"\"" ||
	_die "${DB_REPL_USER} のパスワード変更に失敗しました"
_ssh_db "su -m _postgresql -c \"psql -c \\\"ALTER USER ${DB_MIGRATOR_USER} PASSWORD '${MIGRATOR_PASS}';\\\"\"" ||
	_die "${DB_MIGRATOR_USER} のパスワード変更に失敗しました"
_ssh_db "su -m _postgresql -c \"psql -c \\\"ALTER USER ${DB_PLATFORM_ADMIN_USER} PASSWORD '${PLATFORM_ADMIN_PASS}';\\\"\"" ||
	_die "${DB_PLATFORM_ADMIN_USER} のパスワード変更に失敗しました"
_ssh_db "su -m _postgresql -c \"psql -c \\\"ALTER USER ${DB_PROJECTOR_USER} PASSWORD '${PROJECTOR_PASS}';\\\"\"" ||
	_die "${DB_PROJECTOR_USER} のパスワード変更に失敗しました"
_ok "postgres / ${DB_APP_USER} / ${DB_REPL_USER} / ${DB_MIGRATOR_USER} / ${DB_PLATFORM_ADMIN_USER} / ${DB_PROJECTOR_USER} のパスワードをローテーション"

# owlv スキーマ適用 (存在する場合のみ)。doc/tenant_isolation.md §6.4: owl_app は
# テーブル所有者ではないため、スキーマ適用は owl_migrator として実行する必要がある
# （owl_app で実行すると CREATE POLICY 等が権限不足で失敗する）。
if [ -f "${INFRA_ROOT}/vm-db/schema.sql" ]; then
	_log "owlv スキーマを適用 (owl_migrator)..."
	ssh -i "$BACKUP_KEY" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
		"root@${DB_IP}" "install -d /tmp/owl-schema"
	scp -i "$BACKUP_KEY" -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$KNOWN_HOSTS" \
		"${INFRA_ROOT}/vm-db/schema.sql" "root@${DB_IP}:/tmp/owl-schema/schema.sql"
	# -h を付けない = Unixドメインソケット経由（pg_hba.conf の local 行にマッチさせる）。
	_ssh_db "PGPASSWORD='${MIGRATOR_PASS}' psql -U ${DB_MIGRATOR_USER} ${DB_NAME} -f /tmp/owl-schema/schema.sql" ||
		_die "スキーマ適用に失敗しました"
	_ssh_db "rm -rf /tmp/owl-schema"
	_ok "owlv スキーマ適用"
else
	_info "infra/vm-db/schema.sql が無いためスキーマ適用をスキップ"
fi

# CA 証明書を AP VM へ伝播 (vm-db/ssl/PLACEHOLDER の運用に合わせる)
_log "DB サーバー証明書を AP VM の db-ca.crt として配置..."
TMP_CRT=$(mktemp /tmp/owl-db-ca.XXXXXX.crt)
trap 'rm -f "$TMP_CRT"' EXIT
_scp_from_db "/var/postgresql/data/server.crt" "$TMP_CRT" ||
	_die "server.crt の取得に失敗しました"
_scp_to_ap "$TMP_CRT" "/etc/owl/db-ca.crt" ||
	_die "db-ca.crt の配置に失敗しました"
_ssh_ap "chmod 644 /etc/owl/db-ca.crt"
_ok "db-ca.crt 配置完了 (自己署名証明書。本番 CA 証明書に差し替えるまでの暫定値)"

# AP VM の db.env を実値で生成。PGUSER/PGPASSWORD/PGDATABASE は標準 libpq 変数名
# (Shell.EventStore.connectDb が実際に読むのはこちらのみ — OWL_DB_* という
# 旧アプリ独自命名は何にも読まれない死んだ設定だったため統一した)。
# owlv-app-run (doas 先のラッパー) が owlv-app 権限で source するため、
# 操作者本人には読めない owner-only (600, owner owlv-app) にする。
_log "AP VM の /etc/owl/db.env を実値で生成..."
_ssh_ap "test -f /etc/owl/db.env.template" ||
	_die "/etc/owl/db.env.template が無い。vm-ap/setup.sh の実行 (STEP 8) を確認してください"
_ssh_ap "sed \
        -e 's/^PGUSER=.*/PGUSER=${DB_APP_USER}/' \
        -e 's#^PGPASSWORD=.*#PGPASSWORD=${APP_PASS}#' \
        -e 's/^PGDATABASE=.*/PGDATABASE=${DB_NAME}/' \
        /etc/owl/db.env.template > /etc/owl/db.env
     chmod 600 /etc/owl/db.env
     chown owlv-app /etc/owl/db.env" ||
	_die "db.env の生成に失敗しました"
_ok "/etc/owl/db.env 生成完了 (chmod 600, owner owlv-app)"

# AP VM の db-projector.env を実値で生成 (doc/cqrs.md §8: owlv-projector 専用、
# owl_app とは別の最小権限ロール)。owl-app の db.env と違い PG* の標準 libpq
# 変数名で書く — rc.d スクリプトがこのファイルを source して直接 exec するため
# (owlv-projector は owl-session 経由ではなく rcctl が直接起動するデーモン)。
_log "AP VM の /etc/owl/db-projector.env を実値で生成..."
_ssh_ap "test -f /etc/owl/db-projector.env.template" ||
	_die "/etc/owl/db-projector.env.template が無い。vm-ap/setup.sh の実行 (STEP 8) を確認してください"
_ssh_ap "sed \
        -e 's/^PGUSER=.*/PGUSER=${DB_PROJECTOR_USER}/' \
        -e 's#^PGPASSWORD=.*#PGPASSWORD=${PROJECTOR_PASS}#' \
        -e 's/^PGDATABASE=.*/PGDATABASE=${DB_NAME}/' \
        /etc/owl/db-projector.env.template > /etc/owl/db-projector.env
     chmod 600 /etc/owl/db-projector.env
     chown _owlproject /etc/owl/db-projector.env" ||
	_die "db-projector.env の生成に失敗しました"
# 起動済みなら新しい接続情報で再起動する (一度 connectDb した後は再読込しないため)。
# 未起動 (rcctl が無効/未設定) の場合は無害に失敗を無視する。
_ssh_ap "rcctl restart owlv_projector 2>/dev/null || true"
_ok "/etc/owl/db-projector.env 生成完了 (chmod 600, owlv_projector 再起動)"

_log "DB シークレットローテーション完了"
echo ""
echo "新パスワード (このターミナルにのみ表示。記録は各自の責任で):"
echo "  postgres   : ${PG_PASS}"
echo "  ${DB_APP_USER}    : ${APP_PASS}"
echo "  ${DB_REPL_USER}   : ${REPL_PASS}"
echo "  ${DB_MIGRATOR_USER} : ${MIGRATOR_PASS}"
echo "  ${DB_PLATFORM_ADMIN_USER} : ${PLATFORM_ADMIN_PASS}"
echo "  ${DB_PROJECTOR_USER} : ${PROJECTOR_PASS}"
echo ""
echo "【まだ残っている手動作業】"
echo "  本番 TLS 証明書への差し替え (内部 CA 発行の証明書が必要):"
echo "    vm-db:/var/postgresql/data/server.{key,crt}"
echo "    差し替え後、新しい CA 証明書をこのスクリプトと同じ手順で"
echo "    vm-ap:/etc/owl/db-ca.crt にも配置すること"
