#!/bin/sh
# vm-git/setup.sh — Git VM セットアップ (Forgejo + パッケージレジストリ)
# §3.1: Forgejo はリポジトリ管理とバイナリレジストリを兼ねる
# Forgejo Runner は vm-build で起動し、ここでは CLI によるオフライン登録まで行う
# 実行: provision.sh の STEP 6 から SSH で呼び出す
set -eu

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_info() { _log "    $*"; }
_ok() { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"

OWL_GIT_IP="${OWL_GIT_IP:?OWL_GIT_IP is required}"
FORGEJO_RUNNER_SECRET="${FORGEJO_RUNNER_SECRET:?FORGEJO_RUNNER_SECRET is required}"
FORGEJO_VERSION="${FORGEJO_VERSION:-7.0.4}"
FORGEJO_USER="git"
FORGEJO_HOME="/home/git"
FORGEJO_DATA="/var/forgejo"

# Forgejo セキュリティ値をプロビジョニング時に生成 (Web UI での手動設定を排除)
FORGEJO_SECRET_KEY=$(openssl rand -hex 32)     # 64 文字 hex
FORGEJO_INTERNAL_TOKEN=$(openssl rand -hex 64) # 128 文字 hex
FORGEJO_ADMIN_PASS=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-24)

_log "Git VM セットアップ開始 (${OWL_GIT_IP})"

# ── パッケージ ────────────────────────────────────────────
_log "パッケージインストール"
pkg_add git sqlite3 2>/dev/null
_ok "git / sqlite3"

# ── Forgejo ユーザー ─────────────────────────────────────
id "$FORGEJO_USER" >/dev/null 2>&1 ||
	useradd -m -d "$FORGEJO_HOME" -s /bin/ksh "$FORGEJO_USER"
install -d -m 750 -o git "$FORGEJO_DATA"
_ok "git ユーザー"

# ── Forgejo バイナリ (OpenBSD: ソースからビルド) ─────────────────
# 公式リリースは linux-amd64 / linux-arm64 のみ。OpenBSD は ELF ABI が異なるため実行不可 (§3.1)。
# bindata タグなし: Web UI 資産は disk 上から読む。API と CLI のみ使用するため問題なし。
_log "Forgejo ${FORGEJO_VERSION} をソースからビルド"
FORGEJO_BIN="/usr/local/bin/forgejo"
FORGEJO_SRC="/tmp/forgejo-build"

if [ ! -f "$FORGEJO_BIN" ]; then
	pkg_add go 2>/dev/null || _die "go のインストールに失敗しました"

	ftp -o "${FORGEJO_SRC}.tar.gz" \
		"https://codeberg.org/forgejo/forgejo/archive/v${FORGEJO_VERSION}.tar.gz" ||
		_die "Forgejo ソースのダウンロードに失敗しました (v${FORGEJO_VERSION})"

	mkdir -p "$FORGEJO_SRC"
	tar xzf "${FORGEJO_SRC}.tar.gz" -C "$FORGEJO_SRC" --strip-components=1
	rm -f "${FORGEJO_SRC}.tar.gz"

	(cd "$FORGEJO_SRC" &&
		go build -tags 'sqlite sqlite_unlock_notify' -o "$FORGEJO_BIN" .) ||
		_die "Forgejo のビルドに失敗しました"

	chmod 755 "$FORGEJO_BIN"
	rm -rf "$FORGEJO_SRC"
	_ok "Forgejo バイナリ: ${FORGEJO_BIN}"
else
	_info "Forgejo バイナリ: 既存のためスキップ"
fi

# ── Forgejo 設定 ─────────────────────────────────────────
_log "Forgejo 設定ファイルを配置"
install -d -m 750 -o git "${FORGEJO_DATA}/custom/conf"

cat >"${FORGEJO_DATA}/custom/conf/app.ini" <<EOF
APP_NAME = owlv Git
RUN_USER = git
RUN_MODE = prod

[server]
PROTOCOL         = http
HTTP_ADDR        = ${OWL_GIT_IP}
HTTP_PORT        = 3000
ROOT_URL         = http://${OWL_GIT_IP}:3000/
DISABLE_SSH      = false
SSH_PORT         = 22

[database]
DB_TYPE  = sqlite3
PATH     = ${FORGEJO_DATA}/forgejo.db

[repository]
ROOT = ${FORGEJO_DATA}/repositories

[security]
INSTALL_LOCK         = true
SECRET_KEY           = ${FORGEJO_SECRET_KEY}
INTERNAL_TOKEN       = ${FORGEJO_INTERNAL_TOKEN}

[packages]
ENABLED = true

[log]
MODE      = file
LEVEL     = Warn
ROOT_PATH = /var/log/forgejo

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW  = true
EOF

chown -R git:git "${FORGEJO_DATA}/custom"
install -d -m 750 -o git /var/log/forgejo
_ok "Forgejo 設定"

# ── rc.d サービス ─────────────────────────────────────────
_log "Forgejo サービス登録"
cat >/etc/rc.d/forgejo <<'EOF'
#!/bin/ksh
daemon="/usr/local/bin/forgejo"
daemon_user="git"
daemon_flags="web --config /var/forgejo/custom/conf/app.ini"
daemon_logger="daemon.info"

. /etc/rc.d/rc.subr
rc_cmd $1
EOF
chmod 755 /etc/rc.d/forgejo
rcctl enable forgejo
rcctl start forgejo
_ok "Forgejo 起動"

# ── CLI による初期化 (Web UI 不要) ───────────────────────────
# INSTALL_LOCK = true で起動したため Web UI ウィザードは表示されない。
# DB の初期化完了を待ってから管理者ユーザーと Runner をプロビジョニングする。
_log "Forgejo DB 初期化待機 (最大 30 秒)"
i=0
while [ "$i" -lt 30 ]; do
	su -m git -c "forgejo admin user list \
		--config ${FORGEJO_DATA}/custom/conf/app.ini" >/dev/null 2>&1 && break
	sleep 1
	i=$((i + 1))
done
[ "$i" -lt 30 ] || _die "Forgejo DB の初期化がタイムアウトしました"
_ok "Forgejo DB 初期化確認"

_log "管理者ユーザー作成 (admin)"
su -m git -c "forgejo admin user create \
	--username admin \
	--password '${FORGEJO_ADMIN_PASS}' \
	--email admin@localhost \
	--admin \
	--must-change-password \
	--config ${FORGEJO_DATA}/custom/conf/app.ini" ||
	_info "管理者ユーザーは既存のためスキップ"
_ok "管理者ユーザー"

# オフライン Runner 登録: ネットワークハンドシェイク不要、共有シークレットのみ使用
# build_vm 側は forgejo-runner create-runner-file で同じシークレットを使う (§4.1)
_log "Forgejo Runner をオフライン登録 (vm-build)"
su -m git -c "forgejo forgejo-cli actions register \
	--name vm-build \
	--secret '${FORGEJO_RUNNER_SECRET}' \
	--labels 'openbsd,haskell' \
	--scope '' \
	--config ${FORGEJO_DATA}/custom/conf/app.ini" ||
	_die "Runner のオフライン登録に失敗しました"
_ok "Runner vm-build 登録完了"

_log "Git VM セットアップ完了"
echo ""
echo " 【管理者パスワード — 初回ログイン後に変更してください】"
echo "   admin / ${FORGEJO_ADMIN_PASS}"
echo ""
echo " 【残りの手動作業】"
echo "   1. ホスト経由で Forgejo SSH にアクセスし owlv リポジトリを作成:"
echo "      ssh git@${OWL_GIT_IP} (Forgejo SSH shell)"
echo "      または: ssh -i <prov_key> root@${OWL_GIT_IP} で CLI 操作"
echo "   2. owlv リポジトリを作成:"
echo "      su -m git -c \"forgejo admin repo create --owner admin --name owlv \\"
echo "        --config ${FORGEJO_DATA}/custom/conf/app.ini\""
echo "   3. .forgejo/workflows/build.yml をリポジトリに追加"
