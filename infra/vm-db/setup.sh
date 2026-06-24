#!/bin/sh
# vm-db/setup.sh — DB VM セットアップ (PostgreSQL + RLS)
# §4.7: ECL 計算等の元データを保持。RLS で多重テナント対応。
# §2.1: WAL アーカイブ設定 (pg_basebackup の前提条件)
# 実行: provision.sh の STEP 8 から SSH で呼び出す
set -eu

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_info() { _log "    $*"; }
_ok() { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"

# 環境変数 (provision.sh から注入)
OWL_DB_IP="${OWL_DB_IP:?OWL_DB_IP is required}"
OWL_AP_IP="${OWL_AP_IP:?OWL_AP_IP is required}"
OWL_HOST_IP="${OWL_HOST_IP:-10.0.1.1}"
PG_VERSION="${PG_VERSION:-18}"
DB_NAME="${DB_NAME:-owl}"
DB_APP_USER="${DB_APP_USER:-owl_app}"
DB_REPL_USER="${DB_REPL_USER:-owl_repl}"
# doc/tenant_isolation.md §6.4: owl_app はテーブル所有者にしない（RLSは所有者には
# 適用されないため）。DDL とテーブル所有は owl_migrator、Tenantレジストリの全件参照は
# owl_platform_admin（root_admin_username 経由のブートストラップ管理者専用）に分離する。
DB_MIGRATOR_USER="${DB_MIGRATOR_USER:-owl_migrator}"
DB_PLATFORM_ADMIN_USER="${DB_PLATFORM_ADMIN_USER:-owl_platform_admin}"
# doc/cqrs.md §4.3, §8: owlv-projector 専用ロール。SELECT のみ (INSERT 不可) で
# owl_app とは別の認証情報を使うことで、プロジェクターが乗っ取られても
# events を書き換え/偽造できないことを Postgres 側の権限分離として保証する。
DB_PROJECTOR_USER="${DB_PROJECTOR_USER:-owl_projector}"
AUDIT_IP="${OWL_AUDIT_IP:?OWL_AUDIT_IP is required}"

_log "DB VM セットアップ開始 (${OWL_DB_IP})"

# ── syslog の Audit VM への一方通行転送 (§6.1 鉄則②) ──────────
# auth ファシリティ(su/sudo・sshd ログイン成否)のみを転送する。仕訳金額・
# 顧客名等のドメインデータは PostgreSQL のクエリログ(別ファシリティ)経由でしか
# 出力されないため、auth に絞ることがマスキングの実体になる。
grep -qF "@${AUDIT_IP}" /etc/syslog.conf 2>/dev/null || {
	printf 'auth.*\t\t\t\t\t@%s\n' "${AUDIT_IP}" >>/etc/syslog.conf
	rcctl restart syslogd 2>/dev/null || true
	_ok "syslog.conf に Audit VM (${AUDIT_IP}) への auth.* 転送を追加"
}

# ── OS パッチ適用 (syspatch) ────────────────────────────────
# doc/dev_sec_ops.md §5: 「syspatch の即日適用」が標準統制。STEP 4 の NAT が
# 開いている STEP 8 (このスクリプト実行時) だけが外向き通信を持つ唯一の機会で、
# STEP 9 のロックダウン後は VM から外への通信が一切できなくなる。再実行時は
# 適用済みなら何もしない (syspatch は idempotent)。
_log "syspatch 適用"
syspatch || _info "警告: syspatch に失敗しました (ミラー到達不可の可能性)。後で手動実行: syspatch"
_ok "syspatch"

# ── パッケージ ────────────────────────────────────────────
# OpenBSD のパッケージは点リリースまで含めたフル版番 (例: 18.3) でしか
# 名前解決できず、メジャー番号だけの "postgresql-server-18" は一致しない。
# ports は常に「現行メジャー 1 系統のみ」を postgresql-server として配布する
# 規約 (旧メジャーは postgresql-previous-* に退避される) なので、バージョン
# 番号を付けずにステム名だけで取得し、後段でインストールされたメジャー版が
# PG_VERSION と一致するか検証することで再現性 (§7) を保証する
# (実際に発生: postgresql-server-18 が見つからずインストール失敗。
# 実際のパッケージ名は postgresql-server-18.3)。
_log "PostgreSQL ${PG_VERSION} インストール"
pkg_add postgresql-server postgresql-client ||
	_die "postgresql のインストールに失敗しました"
_installed_pg_major=$(pkg_info | sed -n 's/^postgresql-server-\([0-9]*\)\..*/\1/p')
[ "$_installed_pg_major" = "$PG_VERSION" ] ||
	_die "PostgreSQL メジャー版不一致: 期待=${PG_VERSION} 実際=${_installed_pg_major:-不明} (owl-config.toml の pg_version を確認してください)"
_ok "PostgreSQL ${_installed_pg_major} (期待バージョン ${PG_VERSION} と一致)"

# ── カーネルパラメータ (System V セマフォ / 共有メモリ) ────────
# initdb の bootstrap ステップは単独起動の postgres バックエンドを立ち上げて
# システムカタログを構築するが、その際 SysV セマフォを確保する。OpenBSD の
# GENERIC カーネルデフォルト (kern.seminfo.semmni=10 等) は max_connections=20
# でも不足し、bootstrap バックエンドが semget に失敗して initdb が無言で
# 落ちる (postgresql-server パッケージの pkg-readme が明記する既知の問題)。
# (実際に発生: "running bootstrap script ..." の直後にエラー終了。原因は
# initdb 呼び出しの 2>/dev/null で隠れていた)。
_log "PostgreSQL 用カーネルパラメータを設定..."
_PG_SYSCTL='
kern.seminfo.semmni=60
kern.seminfo.semmns=560
kern.seminfo.semmnu=30
kern.seminfo.semmsl=200
kern.shminfo.shmmax=536870912
kern.shminfo.shmmin=1
kern.shminfo.shmmni=512
kern.shminfo.shmseg=1024
kern.shminfo.shmall=131072
'
# 再実行時に重複追記しないよう、owl-pg マーカー以降を一旦取り除いてから書き直す
sed -i '/^# owl-pg sysctl (postgresql-server)$/,$d' /etc/sysctl.conf 2>/dev/null || true
{
	echo "# owl-pg sysctl (postgresql-server)"
	printf '%s\n' "$_PG_SYSCTL"
} >>/etc/sysctl.conf
printf '%s\n' "$_PG_SYSCTL" | while IFS='=' read -r _k _v; do
	[ -n "$_k" ] || continue
	sysctl "${_k}=${_v}"
done
_ok "カーネルパラメータ設定 (/etc/sysctl.conf に永続化 + 即時反映)"

# ── PostgreSQL 初期化 ─────────────────────────────────────
_log "PostgreSQL 初期化"
install -d -m 700 -o _postgresql /var/postgresql/data

# 他の setup.sh (vm-ap/vm-git/vm-build/vm-audit) はすべて再実行可能だが、
# initdb はデータディレクトリが空でないと即座に失敗するため、この VM だけ
# 再プロビジョニングのたびに setup.sh 全体が initdb で死んでいた
# (実際に発生)。PG_VERSION ファイル(initdb成功時に必ず作られる)の存在で
# 「既に初期化済みか」を判定し、初期化済みならこのブロックを丸ごとスキップする。
if [ -s /var/postgresql/data/PG_VERSION ]; then
	_info "initdb は既に実行済み (PG_VERSION ファイルを検出) のためスキップ"
else
	_initdb_log=/tmp/owl-initdb.log
	# --username=postgres 必須: 省略すると initdb はブートストラップ用スーパーユーザー
	# ロールを「initdb を実行した OS ユーザー名」(_postgresql) で作成する。後段の
	# 全コマンドは "psql -U postgres" を前提にしているため、これが無いと
	# ロール "postgres" がそもそも存在せず、全件が "role does not exist" で失敗し、
	# その失敗が "既に存在します" 側の || フォールバックに握り潰される
	# (実際に発生: 初回実行でも DB ユーザー/データベースが一切作成されないまま
	# "✓ DB ユーザー・データベース作成" が表示されていた)。
	su -m _postgresql -c "initdb -D /var/postgresql/data --username=postgres --auth-local=trust --auth-host=scram-sha-256 --encoding=UTF8 --lc-collate=C --lc-ctype=C --pwprompt --no-instructions" \
		<<'EOF' >"$_initdb_log" 2>&1 || {
changeme_root_password
changeme_root_password
EOF
		cat "$_initdb_log"
		_die "initdb に失敗しました (詳細は上記出力を参照)"
	}
	cat "$_initdb_log"
	rm -f "$_initdb_log"
	_ok "initdb 完了"
fi

# ── 設定ファイルの配置 ────────────────────────────────────
_log "PostgreSQL 設定ファイルを配置"
PGDATA=/var/postgresql/data

install -m 640 -o _postgresql /provision/vm-db/postgresql.conf "${PGDATA}/postgresql.conf"
install -m 640 -o _postgresql /provision/vm-db/pg_hba.conf "${PGDATA}/pg_hba.conf"

# TLS 証明書: セルフサイン (本番運用前に内部 CA 発行に差し替えること)
if [ ! -f "${PGDATA}/server.crt" ]; then
	openssl req -new -x509 -days 3650 -nodes \
		-subj "/CN=vm-db.local/O=owlv" \
		-keyout "${PGDATA}/server.key" \
		-out "${PGDATA}/server.crt" 2>/dev/null
	chmod 600 "${PGDATA}/server.key"
	chown _postgresql "${PGDATA}/server.key" "${PGDATA}/server.crt"
	_info "自己署名 TLS 証明書を生成しました。本番前に内部 CA 発行の証明書に差し替えてください"
fi

# WAL アーカイブ先
install -d -m 750 -o _postgresql /var/postgresql/wal_archive

# postgresql.conf の logging_collector = on / log_directory が指すログ先。
# ディレクトリが存在しないと postmaster がログファイルを開けず起動直後に
# 無言で落ちる (実際に発生: rcctl start postgresql が postgresql(failed) で
# 終了。initdb 自体は成功していたため気付きにくい)。
install -d -m 750 -o _postgresql /var/log/postgresql

# postgresql.conf のプレースホルダーを実際の値に置換
sed -i \
	-e "s|__DB_IP__|${OWL_DB_IP}|g" \
	-e "s|__AP_IP__|${OWL_AP_IP}|g" \
	-e "s|__HOST_IP__|${OWL_HOST_IP}|g" \
	"${PGDATA}/postgresql.conf" "${PGDATA}/pg_hba.conf"

_ok "設定ファイル配置"

# ── PostgreSQL 起動 ───────────────────────────────────────
rcctl enable postgresql
if ! rcctl start postgresql; then
	_log "postgresql 起動失敗 — ログを確認:"
	tail -n 40 /var/log/postgresql/*.log 2>/dev/null | while read -r l; do _info "$l"; done
	tail -n 40 /var/log/daemon 2>/dev/null | grep -i postgres | while read -r l; do _info "$l"; done
	_die "rcctl start postgresql に失敗しました (詳細は上記ログを参照)"
fi
sleep 2

# ── ユーザー・DB 作成 ─────────────────────────────────────
_log "DB ユーザー・データベース作成"

# -U postgres 必須: 省略すると psql は実行 OS ユーザー名 (_postgresql) を
# PG ロールとして使おうとし、pg_hba.conf に一致する行が無く全件 reject される
# (実際に発生: 失敗が "既に存在します" 側に握り潰され、初回実行でもロール/DBが
# 一切作成されないまま "✓" が表示されていた)。
su -m _postgresql -c "psql -U postgres -c \"\
    CREATE USER ${DB_APP_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS \
        ENCRYPTED PASSWORD 'changeme_app_password';\"" 2>/dev/null ||
	_info "${DB_APP_USER} は既に存在します"

su -m _postgresql -c "psql -U postgres -c \"\
    CREATE USER ${DB_REPL_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE REPLICATION \
        ENCRYPTED PASSWORD 'changeme_repl_password';\"" 2>/dev/null ||
	_info "${DB_REPL_USER} は既に存在します"

# テーブル所有者・DDL実行専用。owl_app には所有権を渡さない (doc/tenant_isolation.md §6.4)。
su -m _postgresql -c "psql -U postgres -c \"\
    CREATE USER ${DB_MIGRATOR_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS \
        ENCRYPTED PASSWORD 'changeme_migrator_password';\"" 2>/dev/null ||
	_info "${DB_MIGRATOR_USER} は既に存在します"

# root_admin_username のブートストラップ専用。tenants テーブルの全件参照のみ許可する。
su -m _postgresql -c "psql -U postgres -c \"\
    CREATE USER ${DB_PLATFORM_ADMIN_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS \
        ENCRYPTED PASSWORD 'changeme_platform_admin_password';\"" 2>/dev/null ||
	_info "${DB_PLATFORM_ADMIN_USER} は既に存在します"

# owlv-projector (doc/cqrs.md) 専用。SELECT のみ — INSERT 権限を一切持たない。
su -m _postgresql -c "psql -U postgres -c \"\
    CREATE USER ${DB_PROJECTOR_USER} WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS \
        ENCRYPTED PASSWORD 'changeme_projector_password';\"" 2>/dev/null ||
	_info "${DB_PROJECTOR_USER} は既に存在します"

su -m _postgresql -c "createdb -U postgres -O ${DB_MIGRATOR_USER} ${DB_NAME} 2>/dev/null" ||
	_info "${DB_NAME} は既に存在します"

# RLS を有効化
su -m _postgresql -c "psql -U postgres ${DB_NAME} -c '\
    ALTER DATABASE ${DB_NAME} SET row_security = on;'" || true

_ok "DB ユーザー・データベース作成"

_log "DB VM セットアップ完了"
echo ""
echo " 【重要: 必ず手動変更が必要な設定】"
echo "   1. PostgreSQL の初期パスワードを変更:"
echo "      psql -U postgres -c \"ALTER USER postgres PASSWORD '<strong-pass>';\""
echo "      psql -U postgres -c \"ALTER USER ${DB_APP_USER} PASSWORD '<strong-pass>';\""
echo "      psql -U postgres -c \"ALTER USER ${DB_REPL_USER} PASSWORD '<strong-pass>';\""
echo "      psql -U postgres -c \"ALTER USER ${DB_MIGRATOR_USER} PASSWORD '<strong-pass>';\""
echo "      psql -U postgres -c \"ALTER USER ${DB_PLATFORM_ADMIN_USER} PASSWORD '<strong-pass>';\""
echo "      psql -U postgres -c \"ALTER USER ${DB_PROJECTOR_USER} PASSWORD '<strong-pass>';\""
echo "   2. 本番 TLS 証明書に差し替え: ${PGDATA}/server.{key,crt}"
echo "   3. owlv スキーマ・RLS ポリシーを適用（owl_app ではなく owl_migrator で実行すること。"
echo "      所有者でないと RLS が機能しない — doc/tenant_isolation.md §6.4）:"
echo "      psql -U ${DB_MIGRATOR_USER} ${DB_NAME} -f /provision/vm-db/schema.sql"
