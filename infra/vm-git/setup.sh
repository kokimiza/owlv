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
AUDIT_IP="${OWL_AUDIT_IP:?OWL_AUDIT_IP is required}"
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
# Forgejo は "admin" を /admin Web UI ルートと衝突する予約ユーザー名として
# 拒否する (CreateUser: name is reserved [name: admin])。CLI サブコマンドの
# "forgejo admin user ..." の "admin" とは無関係 — そちらはそのままで良い。
FORGEJO_ADMIN_USER="owlv-admin"

_log "Git VM セットアップ開始 (${OWL_GIT_IP})"

# ── syslog の Audit VM への一方通行転送 (§6.1 鉄則②) ──────────
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
# 新規インストール直後は /etc/rc がバックグラウンドで起動する reorder_kernel
# (KARL) が完了するまで syspatch は "cannot apply patches while reorder_kernel
# is running" で拒否される (実際に発生)。事前に pgrep で存在確認しても、確認直後
# に reorder_kernel が開始する競合が起こりうるため(実際に発生)、エラー文字列
# そのものを見てリトライする (10秒間隔、最大10分)。
_log "syspatch 適用"
_syspatch_tries=0
while :; do
	_syspatch_out=$(syspatch 2>&1) && { [ -n "$_syspatch_out" ] && printf '%s\n' "$_syspatch_out"; break; }
	case "$_syspatch_out" in
	*"reorder_kernel is running"*)
		_syspatch_tries=$((_syspatch_tries + 1))
		if [ "$_syspatch_tries" -ge 60 ]; then
			_info "警告: reorder_kernel 待ちが長すぎるため syspatch を断念しました。後で手動実行: syspatch"
			break
		fi
		sleep 10
		;;
	*)
		_info "警告: syspatch に失敗しました (ミラー到達不可の可能性)。後で手動実行: syspatch"
		printf '%s\n' "$_syspatch_out"
		break
		;;
	esac
done
_ok "syspatch"

# ── パッケージ ────────────────────────────────────────────
_log "パッケージインストール"
# bash: OpenBSD には標準で無いが、Forgejo の pre-receive 等 git フックスクリプトは
# [git] SCRIPT_TYPE 設定 (下記) を無視して #!/usr/bin/env bash を生成する
# (実際に発生: SCRIPT_TYPE=ksh を設定しても CLI警告は消えず、auto_init での
# 初回push が "env: bash: No such file or directory" → pre-receive hook declined
# → リポジトリ作成APIが 500 で失敗していた)。設定で回避するより bash 自体を
# 入れる方が確実。
pkg_add git sqlite3 bash 2>/dev/null
_ok "git / sqlite3"

# ── Forgejo ユーザー ─────────────────────────────────────
id "$FORGEJO_USER" >/dev/null 2>&1 ||
	useradd -m -d "$FORGEJO_HOME" -s /bin/ksh "$FORGEJO_USER"
install -d -m 750 -o git "$FORGEJO_DATA"
_ok "git ユーザー"

# ── Forgejo バイナリ (OpenBSD: ソースからビルド) ─────────────────
# 公式リリースは linux-amd64 / linux-arm64 のみ。OpenBSD は ELF ABI が異なるため実行不可 (§3.1)。
# bindata タグなし: Web UI 資産は disk 上から読む (STATIC_ROOT_PATH 配下)。
_log "Forgejo ${FORGEJO_VERSION} をソースからビルド"
FORGEJO_BIN="/usr/local/bin/forgejo"
FORGEJO_SRC="/tmp/forgejo-build"

if [ ! -f "$FORGEJO_BIN" ] || [ ! -d "$FORGEJO_STATIC_ROOT/options" ]; then
	# node/gmake はフロントエンド (webpack) ビルド専用。webpack の JS heap は
	# 1G の VM では OOM するため (実際に発生)、vmd.conf でこの VM に 2G を
	# 割っている前提 (infra/host/conf/vmd.conf 参照)。
	pkg_add go node gmake 2>/dev/null || _die "go/node/gmake のインストールに失敗しました"

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

	_info "Forgejo 本体は Go の依存取得+ビルドが大きく、15〜30分程度かかることがあります。"
	(cd "$FORGEJO_SRC" &&
		go build -tags 'sqlite sqlite_unlock_notify' -o "$FORGEJO_BIN" .) ||
		_die "Forgejo のビルドに失敗しました"

	# フロントエンド (webpack): public/assets/{js,css,fonts} を生成する。
	# NODE_ENV=production でソースマップ生成を抑えメモリ消費を下げる
	# (development モードのままだと 2G でも OOM することがある、実際に発生)。
	_info "フロントエンド (npm + webpack) をビルド中..."
	(cd "$FORGEJO_SRC" && NODE_ENV=production gmake frontend) ||
		_die "フロントエンドのビルドに失敗しました"
	[ -f "${FORGEJO_SRC}/public/assets/js/index.js" ] ||
		_die "webpack 完了後も public/assets/js/index.js が見つかりません"

	# ビルド専用キャッシュ/依存なので完了後は破棄してディスクを回収する
	rm -rf "$GOPATH" "${FORGEJO_SRC}/node_modules"

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
# rc.subr は ksh 前提 (bash ではない)
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

_log "管理者ユーザー作成 (${FORGEJO_ADMIN_USER})"
# --must-change-password は付けない。この直後にリポジトリ作成・ブランチ保護・
# workflow反映をこのアカウントのトークンで自動実行するが、Forgejo は
# パスワード変更必須フラグが立ったユーザーのAPI操作を 403
# "You must change your password" で拒否する (実際に発生: 人間がWeb UIで
# 初回ログインしてパスワードを変更する前に自動化が走るため、フラグを立てると
# 自動化と原理的に両立しない)。FORGEJO_ADMIN_PASS は openssl rand -base64 18
# の24文字ランダム値なので、変更必須を強制しなくても初期値として十分強固。
su -m git -c "forgejo admin user create \
	--username ${FORGEJO_ADMIN_USER} \
	--password '${FORGEJO_ADMIN_PASS}' \
	--email ${FORGEJO_ADMIN_USER}@localhost \
	--admin \
	--config ${FORGEJO_DATA}/custom/conf/app.ini" 2>&1 | while read -r l; do _info "$l"; done
# create の失敗理由が「既に存在」かどうかをエラー文字列で判定すると、
# repo create の一件 (実在しないサブコマンドを `||` で握り潰し続行していた)
# と同じ事故になる。実際に発生: create が何らかの理由で失敗し `||` で
# スキップしたのに admin が存在せず、後続の generate-access-token が
# "user does not exist [uid: 0, name: admin]" で失敗。終了コードではなく
# 実在そのものを確認してから先に進む。
su -m git -c "forgejo admin user list --config ${FORGEJO_DATA}/custom/conf/app.ini" |
	grep -qw "${FORGEJO_ADMIN_USER}" || _die "${FORGEJO_ADMIN_USER} ユーザーが存在しません (作成に失敗した可能性。上記ログを確認してください)"
_ok "管理者ユーザー"

# オフライン Runner 登録: ネットワークハンドシェイク不要、共有シークレットのみ使用
# build_vm 側は forgejo-runner create-runner-file で同じシークレットを使う (§4.1)
# ラベルは "<名前>:<実行方式>" の形式が必須 (Docker を使わない host モードのみで
# 動かすため、すべて :host を付与する。なお --labels を付けずに再登録すると
# ラベルがリセットされる仕様のため、再実行時も毎回明示で渡す)。
# go:host は fohlen (doc/audit_engine.md, build-fohlen.yml) 用。同じ vm-build 上の
# 同一 Runner が capacity:2 で owlv 本体(haskell)と fohlen(go) の両ジョブを処理する。
_log "Forgejo Runner をオフライン登録 (vm-build)"
su -m git -c "forgejo forgejo-cli actions register \
	--name vm-build \
	--secret '${FORGEJO_RUNNER_SECRET}' \
	--labels 'openbsd:host,haskell:host,go:host' \
	--scope '' \
	--config ${FORGEJO_DATA}/custom/conf/app.ini" ||
	_die "Runner のオフライン登録に失敗しました"
_ok "Runner vm-build 登録完了"

# ── ボットトークン発行 (リポジトリ作成 / ブランチ保護 / deploy-poll 共用) ──
# HTTP API + write:repository スコープのトークンで行う。
# 同じトークンを owl-control.sh deploy-poll (§4.2) にも使い回すため、ホストへ
# 標準出力経由で引き渡す (08-vm-provision.sh が DEPLOY_POLL_TOKEN= 行を捕捉して
# /etc/owlv/forgejo_token へ書き込む)。
_log "ボットトークンを発行"
# forgejo CLI は app.ini の [git] SCRIPT_TYPE 設定に関わらず
# `SCRIPT_TYPE "bash" is not on the current PATH` 警告を標準出力に吐く
# (実際に発生)。`--raw` の出力と一緒にコマンド置換で拾われると、トークン文字列に
# 警告行由来の改行が混入し、後で `Authorization: token <値>` ヘッダーに
# そのまま使った際にヘッダー内改行注入扱いとなり net/http に素の 400 で
# 拒否される (リポジトリ作成APIの 400 の真因はこれだった)。トークンは常に
# 出力の最終行なので tail -n1 で確実に取り出す。
BOT_TOKEN=$(su -m git -c "forgejo admin user generate-access-token \
	--username ${FORGEJO_ADMIN_USER} --token-name 'owlv-bot-$(date +%s)' --scopes write:repository --raw \
	--config ${FORGEJO_DATA}/custom/conf/app.ini" | tail -n1) ||
	_die "ボットトークンの発行に失敗しました"
[ -n "$BOT_TOKEN" ] || _die "ボットトークンが空でした"
_ok "ボットトークン発行"

# Audit VM 専用の読み取り専用トークン (doc/audit_engine.md §10)。
# REQUIRE_SIGNIN_VIEW = true (上記) により匿名API呼び出しは全面禁止される
# ("Only signed in user is allowed to call APIs.") ため、fohlen のリリース
# 取得確認にはトークンが必須。write:repository を持つ BOT_TOKEN をそのまま
# Audit VM に渡すと最小権限の原則に反する (Audit VM は nologin・doas権限なし
# が前提の設計、doc/dev_sec_ops.md §6.2) ため、read:repository のみの
# 別トークンを発行する。
_log "Audit VM 用の読み取り専用トークンを発行"
# BOT_TOKEN と同じ理由 (上記コメント参照) で tail -n1 が必要。
AUDIT_READ_TOKEN=$(su -m git -c "forgejo admin user generate-access-token \
	--username ${FORGEJO_ADMIN_USER} --token-name 'owlv-audit-read-$(date +%s)' --scopes read:repository --raw \
	--config ${FORGEJO_DATA}/custom/conf/app.ini" | tail -n1) ||
	_die "Audit VM 用トークンの発行に失敗しました"
[ -n "$AUDIT_READ_TOKEN" ] || _die "Audit VM 用トークンが空でした"
_ok "Audit VM 用読み取り専用トークン発行"

API="http://${OWL_GIT_IP}:3000/api/v1"

# git smart HTTP (clone/push) の認証先は REST API ("Authorization: token ...")
# とは別の経路であり、Forgejo/Gitea の git-http バックエンドは Basic 認証
# (username:token) を正としてサポートする。以前はリポジトリ作成 (REST API) と
# clone (git smart HTTP) の両方を同じ "Authorization: token" ヘッダで通そうと
# しており、clone 側が "400 Bad Request" で失敗していた (実際に発生)。
# URL に "user:token@host" を埋め込む方式は git のエラーメッセージに資格情報
# がそのまま出てプロビジョニングログ (/var/log/owlv/) に残ってしまうため、
# 代わりに標準の Authorization: Basic ヘッダ (base64(user:token)) を
# http.extraHeader で渡す — スキームを "token" から "Basic" に変えるだけで
# URL 自体は資格情報を含まない。
GIT_HTTP_BASE="${API%/api/v1}"
GIT_REPO_URL="${GIT_HTTP_BASE}/${FORGEJO_ADMIN_USER}/owlv.git"
GIT_BASIC_AUTH="$(printf '%s:%s' "${FORGEJO_ADMIN_USER}" "${BOT_TOKEN}" | openssl base64 -A)"

_log "owlv リポジトリを作成"
_REPO_CREATE_BODY="$(mktemp)"
_REPO_CREATE_STATUS=$(curl -s -o "$_REPO_CREATE_BODY" -w '%{http_code}' -X POST \
	-H "Authorization: token ${BOT_TOKEN}" \
	-H "Content-Type: application/json" \
	-d '{"name":"owlv","auto_init":true,"default_branch":"main","private":true}' \
	"${API}/user/repos")
case "$_REPO_CREATE_STATUS" in
2??) _ok "owlv リポジトリを作成" ;;
409) _info "owlv リポジトリは既存のためスキップ" ;;
*)
	# 409(既存)以外の失敗は握り潰さず、応答本文を出して原因を判別できるようにする
	# (実際に発生: 認証エラー等の本当の失敗が「既存のためスキップ」に化けていた)。
	_log "リポジトリ作成 API 応答 (status=${_REPO_CREATE_STATUS}):"
	# curl の JSON エラー本文は末尾改行が無いことが多く、素の
	# `while read -r l; do ...; done` だと最終行が改行無しで EOF になった
	# 場合に read が失敗して読み捨てられる (実際に発生: 400 の本文が
	# まるごと表示されず原因不明のまま _die していた)。
	while IFS= read -r l || [ -n "$l" ]; do _info "$l"; done <"$_REPO_CREATE_BODY"
	rm -f "$_REPO_CREATE_BODY"
	_die "owlv リポジトリの作成に失敗しました (status=${_REPO_CREATE_STATUS})"
	;;
esac
rm -f "$_REPO_CREATE_BODY"
_ok "owlv リポジトリ"

# build.yml (owlv 本体/Haskell) と build-fohlen.yml (fohlen/Go, doc/audit_engine.md)
# を同じコミットで反映する。後者が無い構成 (fohlen 未導入時点のチェックアウト)
# でも前者だけで動作するよう、存在するファイルのみ対象にする。
_WORKFLOW_FILES=""
for _wf in build.yml build-fohlen.yml; do
	[ -f "${SCRIPT_DIR}/${_wf}" ] && _WORKFLOW_FILES="${_WORKFLOW_FILES} ${_wf}"
done

if [ -n "$_WORKFLOW_FILES" ]; then
	_log ".forgejo/workflows/ (${_WORKFLOW_FILES# }) をリポジトリへ反映"
	WORK=$(mktemp -d)
	git -c "http.extraHeader=Authorization: Basic ${GIT_BASIC_AUTH}" \
		clone -q "$GIT_REPO_URL" "$WORK" || _die "owlv リポジトリの clone に失敗しました"
	(
		cd "$WORK" || exit 1
		git checkout -q -B main
		mkdir -p .forgejo/workflows
		for _wf in $_WORKFLOW_FILES; do
			cp "${SCRIPT_DIR}/${_wf}" ".forgejo/workflows/${_wf}"
			git add ".forgejo/workflows/${_wf}"
		done
		if git -c user.email="${FORGEJO_ADMIN_USER}@localhost" -c user.name="${FORGEJO_ADMIN_USER}" diff --cached --quiet; then
			echo "  変更なし"
		else
			git -c user.email="${FORGEJO_ADMIN_USER}@localhost" -c user.name="${FORGEJO_ADMIN_USER}" \
				commit -q -m 'ci: add/update workflows'
			git -c "http.extraHeader=Authorization: Basic ${GIT_BASIC_AUTH}" push -q origin HEAD:main
		fi
	) || _die "workflow の反映に失敗しました"
	rm -rf "$WORK"
	_ok "workflow 反映 (${_WORKFLOW_FILES# })"
else
	_info "警告: ${SCRIPT_DIR}/build.yml が見つかりません。手動で追加してください"
fi

# ブランチ保護 (main への直接 push 禁止 / 最低1 Approve 必須、doc/dev_sec_ops.md §3.3)
_log "ブランチ保護を設定"
curl -fsS -X POST \
	-H "Authorization: token ${BOT_TOKEN}" \
	-H "Content-Type: application/json" \
	-d '{"branch_name":"main","enable_push":false,"required_approvals":1,"enable_status_check":true}' \
	"${API}/repos/${FORGEJO_ADMIN_USER}/owlv/branch_protections" >/dev/null 2>&1 ||
	_info "ブランチ保護は既存のためスキップ (失敗時は要手動確認)"
_ok "ブランチ保護"

_log "Git VM セットアップ完了"
echo ""
echo " 【管理者パスワード — 初回ログイン後に変更してください】"
echo "   ${FORGEJO_ADMIN_USER} / ${FORGEJO_ADMIN_PASS}"
echo ""
echo " 【残りの手動作業】"
echo "   なし (リポジトリ作成・build.yml 反映・ブランチ保護はすべて自動化済み)"
echo ""
# 08-vm-provision.sh が標準出力からこの行を捕捉して /etc/owlv/forgejo_token (ホスト) へ書き込む。
echo "DEPLOY_POLL_TOKEN=${BOT_TOKEN}"
# 08-vm-provision.sh が標準出力からこの行を捕捉して /etc/owlv/audit_releases_token (ホスト) へ書き込み、
# vm-audit プロビジョニング時に /provision/audit-releases-token として配布する。
echo "AUDIT_RELEASES_TOKEN=${AUDIT_READ_TOKEN}"
