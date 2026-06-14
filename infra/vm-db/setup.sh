#!/bin/sh
# vm-db/setup.sh — DB VM セットアップ (PostgreSQL + RLS)
# §4.7: ECL 計算等の元データを保持。RLS で多重テナント対応。
# §2.1: WAL アーカイブ設定 (pg_basebackup の前提条件)
# 実行: provision.sh の STEP 6 から SSH で呼び出す
set -eu

_log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die()  { _log "エラー: $*" >&2; exit 1; }
_info() { _log "    $*"; }
_ok()   { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"

# 環境変数 (provision.sh から注入)
OWL_DB_IP="${OWL_DB_IP:?OWL_DB_IP is required}"
OWL_AP_IP="${OWL_AP_IP:?OWL_AP_IP is required}"
OWL_HOST_IP="${OWL_HOST_IP:-10.0.1.1}"
PG_VERSION="${PG_VERSION:-16}"
DB_NAME="${DB_NAME:-owl}"
DB_APP_USER="${DB_APP_USER:-owl_app}"
DB_REPL_USER="${DB_REPL_USER:-owl_repl}"

_log "DB VM セットアップ開始 (${OWL_DB_IP})"

# ── パッケージ ────────────────────────────────────────────
_log "PostgreSQL ${PG_VERSION} インストール"
pkg_add "postgresql-server-${PG_VERSION}" "postgresql-client-${PG_VERSION}" \
    || _die "postgresql のインストールに失敗しました"
_ok "PostgreSQL ${PG_VERSION}"

# ── PostgreSQL 初期化 ─────────────────────────────────────
_log "PostgreSQL 初期化"
install -d -m 700 -o _postgresql /var/postgresql/data
su -m _postgresql -c "initdb -D /var/postgresql/data --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 --lc-collate=C --lc-ctype=C --pwprompt --no-instructions 2>/dev/null" \
    << 'EOF'
changeme_root_password
changeme_root_password
EOF
_ok "initdb 完了"

# ── 設定ファイルの配置 ────────────────────────────────────
_log "PostgreSQL 設定ファイルを配置"
PGDATA=/var/postgresql/data

install -m 640 -o _postgresql /provision/vm-db/postgresql.conf "${PGDATA}/postgresql.conf"
install -m 640 -o _postgresql /provision/vm-db/pg_hba.conf     "${PGDATA}/pg_hba.conf"

# TLS 証明書: セルフサイン (本番運用前に内部 CA 発行に差し替えること)
if [ ! -f "${PGDATA}/server.crt" ]; then
    openssl req -new -x509 -days 3650 -nodes \
        -subj "/CN=vm-db.local/O=owlv" \
        -keyout "${PGDATA}/server.key" \
        -out    "${PGDATA}/server.crt" 2>/dev/null
    chmod 600 "${PGDATA}/server.key"
    chown _postgresql "${PGDATA}/server.key" "${PGDATA}/server.crt"
    _info "自己署名 TLS 証明書を生成しました。本番前に内部 CA 発行の証明書に差し替えてください"
fi

# WAL アーカイブ先
install -d -m 750 -o _postgresql /var/postgresql/wal_archive

# postgresql.conf のプレースホルダーを実際の値に置換
sed -i \
    -e "s|__DB_IP__|${OWL_DB_IP}|g" \
    -e "s|__AP_IP__|${OWL_AP_IP}|g" \
    -e "s|__HOST_IP__|${OWL_HOST_IP}|g" \
    "${PGDATA}/postgresql.conf" "${PGDATA}/pg_hba.conf"

_ok "設定ファイル配置"

# ── PostgreSQL 起動 ───────────────────────────────────────
rcctl enable postgresql
rcctl start postgresql
sleep 2

# ── ユーザー・DB 作成 ─────────────────────────────────────
_log "DB ユーザー・データベース作成"

su -m _postgresql -c "psql -c \"\
    CREATE USER ${DB_APP_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE \
        ENCRYPTED PASSWORD 'changeme_app_password';\"" 2>/dev/null || \
    _info "${DB_APP_USER} は既に存在します"

su -m _postgresql -c "psql -c \"\
    CREATE USER ${DB_REPL_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE REPLICATION \
        ENCRYPTED PASSWORD 'changeme_repl_password';\"" 2>/dev/null || \
    _info "${DB_REPL_USER} は既に存在します"

su -m _postgresql -c "createdb -O ${DB_APP_USER} ${DB_NAME} 2>/dev/null" || \
    _info "${DB_NAME} は既に存在します"

# RLS を有効化
su -m _postgresql -c "psql ${DB_NAME} -c '\
    ALTER DATABASE ${DB_NAME} SET row_security = on;'" || true

_ok "DB ユーザー・データベース作成"

_log "DB VM セットアップ完了"
echo ""
echo " 【重要: 必ず手動変更が必要な設定】"
echo "   1. PostgreSQL の初期パスワードを変更:"
echo "      psql -U postgres -c \"ALTER USER postgres PASSWORD '<strong-pass>';\""
echo "      psql -U postgres -c \"ALTER USER ${DB_APP_USER} PASSWORD '<strong-pass>';\""
echo "      psql -U postgres -c \"ALTER USER ${DB_REPL_USER} PASSWORD '<strong-pass>';\""
echo "   2. 本番 TLS 証明書に差し替え: ${PGDATA}/server.{key,crt}"
echo "   3. owlv スキーマ・RLS ポリシーを適用:"
echo "      psql -U ${DB_APP_USER} ${DB_NAME} -f /provision/vm-db/schema.sql"
