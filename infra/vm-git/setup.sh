#!/bin/sh
# vm-git/setup.sh — Git VM セットアップ (Forgejo + パッケージレジストリ)
# §3.1: Forgejo はリポジトリ管理とバイナリレジストリを兼ねる
# Forgejo Runner は vm-build で起動し、ここでは CLI によるオフライン登録まで行う
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

# build.yml は infra/vm-git/build.yml に同居させてあり、08-vm-provision.sh の
# scp -r が setup.sh と一緒に /provision/vm-git/ へ転送する (手動配置は不要)。
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

OWL_GIT_IP="${OWL_GIT_IP:?OWL_GIT_IP is required}"
FORGEJO_RUNNER_SECRET="${FORGEJO_RUNNER_SECRET:?FORGEJO_RUNNER_SECRET is required}"
# 既定値は owl-config.toml [forgejo].version と一致させておく
# (08-vm-provision.sh が通常はそちらを env 経由で渡す)
FORGEJO_VERSION="${FORGEJO_VERSION:-15.0.3}"
FORGEJO_USER="git"
FORGEJO_HOME="/home/git"
FORGEJO_DATA="/var/forgejo"
FORGEJO_STATIC_ROOT="/usr/local/share/forgejo"

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

if [ ! -f "$FORGEJO_BIN" ] || [ ! -d "$FORGEJO_STATIC_ROOT/options" ]; then
	pkg_add go 2>/dev/null || _die "go のインストールに失敗しました"

	ftp -o "${FORGEJO_SRC}.tar.gz" \
		"https://codeberg.org/forgejo/forgejo/archive/v${FORGEJO_VERSION}.tar.gz" ||
		_die "Forgejo ソースのダウンロードに失敗しました (v${FORGEJO_VERSION})"

	# OpenBSD 標準の tar は GNU 拡張の --strip-components を解釈できず、
	# フラグそのものを展開対象パターンとして扱って "patterns were not
	# matched" になる (実際に発生)。アーカイブのトップレベルディレクトリを
	# 一旦別の場所に展開し、それ自体を目的のパスへ rename することで
	# 同等の効果を得る。
	mkdir -p "${FORGEJO_SRC}.extract"
	tar xzf "${FORGEJO_SRC}.tar.gz" -C "${FORGEJO_SRC}.extract"
	rm -f "${FORGEJO_SRC}.tar.gz"
	_forgejo_top=$(find "${FORGEJO_SRC}.extract" -mindepth 1 -maxdepth 1 -type d | head -1)
	[ -n "$_forgejo_top" ] || _die "Forgejo ソース展開後にトップレベルディレクトリが見つかりません"
	rm -rf "$FORGEJO_SRC"
	mv "$_forgejo_top" "$FORGEJO_SRC"
	rmdir "${FORGEJO_SRC}.extract" 2>/dev/null || true

	# go のモジュールキャッシュ ($HOME/go = /root/go) は OpenBSD インストーラーの
	# 自動パーティショニングで "/" に割り当てられる小さな領域に乗ってしまい、
	# bleve (全文検索) 等の依存が肥大で容量を使い切る (実際に発生:
	# "no space left on device" で go build が失敗)。/usr は自動レイアウトで
	# 大きく確保される側のパーティションなので、そちら配下にキャッシュを移す。
	_log "GOPATH/GOCACHE を /usr/local 配下へ退避 (/ パーティション枯渇回避)"
	# 前回失敗時に /root/go へ書きかけたキャッシュが残っていると "/" を
	# 圧迫し続けるので、再実行時のために必ず破棄しておく
	rm -rf /root/go
	export GOPATH=/usr/local/go-workspace
	export GOCACHE=/usr/local/go-workspace/cache
	install -d "$GOPATH" "$GOCACHE"

	(cd "$FORGEJO_SRC" &&
		go build -tags 'sqlite sqlite_unlock_notify' -o "$FORGEJO_BIN" .) ||
		_die "Forgejo のビルドに失敗しました"

	# ビルド専用キャッシュなので完了後は破棄してディスクを回収する
	rm -rf "$GOPATH"

	# bindata タグなしビルドは options/ (ロケール) public/ templates/ を
	# 実行時に disk から読む (STATIC_ROOT_PATH 配下)。ソースツリー削除前に
	# 永続先へ退避しておく (これを怠ると翻訳ファイル欠落で起動時に fatal)
	install -d "$FORGEJO_STATIC_ROOT"
	cp -R "$FORGEJO_SRC/options" "$FORGEJO_SRC/public" "$FORGEJO_SRC/templates" \
		"$FORGEJO_STATIC_ROOT/"
	chown -R root:wheel "$FORGEJO_STATIC_ROOT"

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
WORK_PATH     = ${FORGEJO_DATA}
APP_DATA_PATH = ${FORGEJO_DATA}/data

[server]
PROTOCOL         = http
HTTP_ADDR        = ${OWL_GIT_IP}
HTTP_PORT        = 3000
ROOT_URL         = http://${OWL_GIT_IP}:3000/
DISABLE_SSH      = false
SSH_PORT         = 22
STATIC_ROOT_PATH = ${FORGEJO_STATIC_ROOT}

[database]
DB_TYPE  = sqlite3
PATH     = ${FORGEJO_DATA}/forgejo.db

[repository]
ROOT = ${FORGEJO_DATA}/repositories

[git]
# OpenBSD には bash が標準で存在しないため、git フック用スクリプトの
# シェルを ksh に固定する (git ユーザーのログインシェルと一致させる。
# 既定値 bash は SCRIPT_TYPE 警告の原因)
SCRIPT_TYPE = ksh

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
# rc.subr は ksh 前提 (bash ではない。app.ini の [git] SCRIPT_TYPE と同様の理由)
daemon="/usr/local/bin/forgejo"
daemon_user="git"
daemon_flags="web --config /var/forgejo/custom/conf/app.ini"
daemon_logger="daemon.info"
# 初回起動は SQLite スキーマの自動マイグレーション (~80 テーブル) が走り、
# rc.subr の既定 30 秒では非力な VM 上でタイムアウトすることがある
daemon_timeout=180
# forgejo web は自分自身をデーモン化(fork+detach)しない。rc_bg を立てないと
# rc.subr は子プロセスが detach するのを待ち続け、フォアグラウンドで動き
# 続ける forgejo に対して毎回 daemon_timeout 一杯まで待って失敗する
# (実際に発生: ログにはプロセス起動成功が出るのに rcctl start は timeout 終了)
rc_bg="YES"

. /etc/rc.d/rc.subr
rc_cmd $1
EOF
chmod 755 /etc/rc.d/forgejo
rcctl enable forgejo
if ! rcctl start forgejo; then
	_log "forgejo 起動失敗 — ログを確認:"
	tail -n 40 /var/log/daemon 2>/dev/null | grep -i forgejo | while read -r l; do _info "$l"; done
	tail -n 40 /var/log/forgejo/*.log 2>/dev/null | while read -r l; do _info "$l"; done
	_die "rcctl start forgejo に失敗しました (詳細は上記ログを参照)"
fi
_ok "Forgejo 起動"

# ── CLI による初期化 ───────────────────────────
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
# ラベルは "<名前>:<実行方式>" の形式が必須 (Docker を使わない host モードのみで
# 動かすため、すべて :host を付与する。なお --labels を付けずに再登録すると
# ラベルがリセットされる仕様のため、再実行時も毎回明示で渡す)。
_log "Forgejo Runner をオフライン登録 (vm-build)"
su -m git -c "forgejo forgejo-cli actions register \
	--name vm-build \
	--secret '${FORGEJO_RUNNER_SECRET}' \
	--labels 'openbsd:host,haskell:host' \
	--scope '' \
	--config ${FORGEJO_DATA}/custom/conf/app.ini" ||
	_die "Runner のオフライン登録に失敗しました"
_ok "Runner vm-build 登録完了"

# ── owlv リポジトリ作成 + build.yml 反映 (Web UI 手動操作を排除) ──────────
# 以前は「リポジトリ作成」「.forgejo/workflows/build.yml の追加」を Web UI
# 経由の手動作業としていたが、両方とも CLI/ローカル git 操作だけで成立するため
# 自動化する。push は Forgejo の HTTP API ではなく、git ユーザーが所有する
# ベアリポジトリへ直接ローカルクローン+push することで、トークン発行なしに
# 完結させる (このホップは TLS 不要、同一VM内のファイルシステム操作のため)。
_log "owlv リポジトリを作成"
su -m git -c "forgejo admin repo create --owner admin --name owlv \
	--config ${FORGEJO_DATA}/custom/conf/app.ini" 2>/dev/null ||
	_info "owlv リポジトリは既存のためスキップ"
_ok "owlv リポジトリ"

REPO_GIT_DIR="${FORGEJO_DATA}/repositories/admin/owlv.git"
if [ -f "${SCRIPT_DIR}/build.yml" ]; then
	_log ".forgejo/workflows/build.yml をリポジトリへ反映"
	su -m git -c "
		set -e
		WORK=\$(mktemp -d)
		git clone -q '${REPO_GIT_DIR}' \"\$WORK\"
		cd \"\$WORK\"
		git checkout -q -B main
		mkdir -p .forgejo/workflows
		cp '${SCRIPT_DIR}/build.yml' .forgejo/workflows/build.yml
		git add .forgejo/workflows/build.yml
		if git diff --cached --quiet; then
			echo '  変更なし'
		else
			git -c user.email='admin@localhost' -c user.name='admin' \
				commit -q -m 'ci: add/update build.yml'
			git push -q origin HEAD:main
		fi
		rm -rf \"\$WORK\"
	" || _die "build.yml の反映に失敗しました"
	_ok "build.yml 反映"
else
	_info "警告: ${SCRIPT_DIR}/build.yml が見つかりません。手動で追加してください"
fi

_log "Git VM セットアップ完了"
echo ""
echo " 【管理者パスワード — 初回ログイン後に変更してください】"
echo "   admin / ${FORGEJO_ADMIN_PASS}"
echo ""
echo " 【残りの手動作業】"
echo "   (リポジトリ作成と build.yml 反映は本スクリプトが完了済み)"
echo "   1. ブランチ保護 (main への直接 push 禁止 / 最低1 Approve 必須、doc/dev_sec_ops.md §3.3):"
echo "      su -m git -c \"forgejo admin user generate-access-token \\"
echo "        --username admin --token-name branch-protect --scopes write:repository \\"
echo "        --config ${FORGEJO_DATA}/custom/conf/app.ini\""
echo "      curl -X POST -H 'Authorization: token <上記トークン>' \\"
echo "        -H 'Content-Type: application/json' \\"
echo "        http://${OWL_GIT_IP}:3000/api/v1/repos/admin/owlv/branch_protections \\"
echo "        -d '{\"branch_name\":\"main\",\"enable_push\":false,\"required_approvals\":1,\"enable_status_check\":true}'"
echo "   2. owl-control.sh deploy-poll (doc/dev_sec_ops.md §4.2) 用トークンを発行し、"
echo "      ホスト側の /etc/owlv/forgejo_token (mode 600, root 所有) に手動投入:"
echo "      su -m git -c \"forgejo admin user generate-access-token \\"
echo "        --username admin --token-name deploy-poll --scopes read:repository,write:repository \\"
echo "        --config ${FORGEJO_DATA}/custom/conf/app.ini\""
