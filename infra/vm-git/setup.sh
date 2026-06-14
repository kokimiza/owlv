#!/bin/sh
# vm-git/setup.sh — Git VM セットアップ (Forgejo + パッケージレジストリ)
# §3.1: Forgejo はリポジトリ管理とバイナリレジストリを兼ねる
# Forgejo Runner は vm-build で起動し、ここでは Runner トークンの発行まで行う
# 実行: provision.sh の STEP 6 から SSH で呼び出す
set -eu

_log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die()  { _log "エラー: $*" >&2; exit 1; }
_info() { _log "    $*"; }
_ok()   { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"

OWL_GIT_IP="${OWL_GIT_IP:?OWL_GIT_IP is required}"
FORGEJO_VERSION="${FORGEJO_VERSION:-7.0.4}"
FORGEJO_USER="git"
FORGEJO_HOME="/home/git"
FORGEJO_DATA="/var/forgejo"

_log "Git VM セットアップ開始 (${OWL_GIT_IP})"

# ── パッケージ ────────────────────────────────────────────
_log "パッケージインストール"
pkg_add git sqlite3 2>/dev/null
_ok "git / sqlite3"

# ── Forgejo ユーザー ─────────────────────────────────────
id "$FORGEJO_USER" >/dev/null 2>&1 || \
    useradd -m -d "$FORGEJO_HOME" -s /bin/ksh "$FORGEJO_USER"
install -d -m 750 -o git "$FORGEJO_DATA"
_ok "git ユーザー"

# ── Forgejo バイナリ取得 ──────────────────────────────────
_log "Forgejo ${FORGEJO_VERSION} をダウンロード"
FORGEJO_BIN="/usr/local/bin/forgejo"
FORGEJO_URL="https://codeberg.org/forgejo/forgejo/releases/download/v${FORGEJO_VERSION}/forgejo-${FORGEJO_VERSION}-linux-amd64"

if [ ! -f "$FORGEJO_BIN" ]; then
    ftp -o "$FORGEJO_BIN" "$FORGEJO_URL" \
        || _die "Forgejo のダウンロードに失敗しました: ${FORGEJO_URL}"
    chmod 755 "$FORGEJO_BIN"
    _ok "Forgejo バイナリ: ${FORGEJO_BIN}"
else
    _info "Forgejo バイナリ: 既存のためスキップ"
fi

# ── Forgejo 設定 ─────────────────────────────────────────
_log "Forgejo 設定ファイルを配置"
install -d -m 750 -o git "${FORGEJO_DATA}/custom/conf"

cat > "${FORGEJO_DATA}/custom/conf/app.ini" <<EOF
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
INSTALL_LOCK         = false
SECRET_KEY           = changeme_replace_with_random_64chars
INTERNAL_TOKEN       = changeme_replace_with_random_128chars

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
cat > /etc/rc.d/forgejo <<'EOF'
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

_log "Git VM セットアップ完了"
echo ""
echo " 【重要: 必ず手動で実施してください】"
echo "   1. ブラウザで http://${OWL_GIT_IP}:3000 にアクセスして初期設定"
echo "      - SECRET_KEY / INTERNAL_TOKEN をランダム値に変更"
echo "      - 管理者アカウントを作成"
echo "   2. owl/owlv リポジトリを作成"
echo "   3. 【CI/CD 連携】Forgejo Runner トークンを発行して vm-build に登録:"
echo "      Settings → Actions → Runners → Create new runner"
echo "      (発行したトークンを vm-build の setup.sh 実行後に登録)"
