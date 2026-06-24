#!/bin/sh
# vm-ap/setup.sh — AP VM セットアップ (owlv TUI アプリケーション)
# §1.4: 運用グループはシェルなし、owlv が直接起動される
# §3.1: Forgejo レジストリからバイナリを取得してインストール
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

# 環境変数 (provision.sh から注入される)
OWL_AP_IP="${OWL_AP_IP:?OWL_AP_IP is required}"
OWL_DB_IP="${OWL_DB_IP:?OWL_DB_IP is required}"
GIT_IP="${OWL_GIT_IP:?OWL_GIT_IP is required}"
AUDIT_IP="${OWL_AUDIT_IP:?OWL_AUDIT_IP is required}"
APP_SSH_PORT="${APP_SSH_PORT:-8022}"
# owl-config.toml [app] の DB 名・ロール名 (db.env.template / db-projector.env.template
# で使う)。vm-db/setup.sh が CREATE USER/createdb する実際のロール・DB名と
# 一致させる必要があるため、ハードコードではなく同じ変数経由で受け取る
# (実際に発生していた問題: 以前は両テンプレートに "owl_app"/"owl_projector"/
# "owl" を直接書いていたため、owl-config.toml 側を変更しても反映されなかった)。
DB_NAME="${DB_NAME:-owl}"
DB_APP_USER="${DB_APP_USER:-owl_app}"
DB_PROJECTOR_USER="${DB_PROJECTOR_USER:-owl_projector}"

# doc/user.md §7: Admin を自動生成してよい唯一のOSユーザー名 (owl-config.toml [user])
ROOT_ADMIN_USERNAME="${OWLV_ROOT_ADMIN_USERNAME:-}"

_log "AP VM セットアップ開始 (${OWL_AP_IP})"

# ── syslog の Audit VM への一方通行転送 (§6.1 鉄則②) ──────────
# auth ファシリティ(su/sudo・sshd ログイン成否)のみを転送する。仕訳金額・
# 顧客名等のドメインデータは owlv アプリのログ出力(auth とは別ファシリティ)
# 経由では一切 syslog に流していないため、ここでの転送対象を auth に絞ること
# 自体がマスキングの実体になる。
grep -qF "@${AUDIT_IP}" /etc/syslog.conf 2>/dev/null || {
	printf 'auth.*\t\t\t\t\t@%s\n' "${AUDIT_IP}" >>/etc/syslog.conf
	rcctl restart syslogd 2>/dev/null || true
	_ok "syslog.conf に Audit VM (${AUDIT_IP}) への auth.* 転送を追加"
}

# ── パッケージ ────────────────────────────────────────────
_log "パッケージインストール"
pkg_add -x bash 2>/dev/null || true # owlv は ksh/sh で動作するが念のため
# owlv バイナリは direct-sqlite が静的コンパイルした SQLite を内包しており
# 動的リンク依存は無い。ここでの sqlite3 は /var/lib/owlv/readmodel/*.sqlite3
# を運用者が直接調査するための CLI ツール用途のみ (doc/cqrs.md §7)。
pkg_add sqlite3 2>/dev/null || _info "警告: sqlite3 が見つかりません。手動でインストールしてください: pkg_add sqlite3"
_ok "パッケージ"

# ── ユーザー・グループ (doc/user.md §2/§3) ──────────────────────────
_log "グループ・ユーザー設定"

groupadd owl-operators 2>/dev/null || true
groupadd owl-maintainers 2>/dev/null || true

# owl-operators: ForceCommand によりシェルを触れない
# owl-maintainers: 通常の ksh シェル + sudo 相当の権限なし (参照専用の保守者)
_ok "グループ作成 (owl-operators / owl-maintainers)"

# owlv-app: owlv 本体を実際に動かす専用サービスアカウント。
# 接続してきた本人(alice 等)の OS アカウントには doas 権限を一切与えない —
# 昇格できるのは owlv-app だけ、かつ owlv-app が呼べるのは owl-user-sync 一本だけ
# (doc/user.md §3.2: cron_batch.md の _owlbatch と同じゼロ権限委譲パターン)。
# 実ホームを持たせる (/nonexistent ではない) — DB 接続情報 (db.env) を
# owlv-app 自身が所有するファイルとして読むため (後述、§ DB 接続環境変数)。
id owlv-app >/dev/null 2>&1 || useradd -s /sbin/nologin -d /var/lib/owlv-app -m owlv-app
_ok "owlv-app サービスアカウント"

# _owlproject: doc/cqrs.md の owlv-projector 専用サービスアカウント。
# cron_batch.md の _owlbatch と同じゼロ権限パターン — doas.conf には一切
# 何も許可しない (このユーザーから root へ上がる経路は存在しない)。
# Postgresの認証情報は owl_app と別ロール (owl_projector、SELECT専用) を使うため、
# 万が一このプロセスが乗っ取られても Postgres 側のイベントを書き換える/偽造する
# ことはできない (doc/cqrs.md §4.3, §8)。
id _owlproject >/dev/null 2>&1 ||
	useradd -u 801 -s /sbin/nologin -d /var/lib/owlproject -m _owlproject
install -d -m 700 -o _owlproject /var/lib/owlproject
_ok "_owlproject サービスアカウント"

# owl-readmodel: SQLiteリードモデル (doc/cqrs.md §4) への読み取りアクセス専用グループ。
# 書き込みは _owlproject (ファイル所有者) のみ。owlv-app はこのグループ経由で
# 読み取り専用 (SQLITE_OPEN_READONLY) でしかアクセスできない (§4.2 のHaskell型束縛に
# 加え、OSパーミッションでも書き込み不可を多重に保証する)。
groupadd owl-readmodel 2>/dev/null || true
usermod -G owl-readmodel owlv-app
usermod -G owl-readmodel _owlproject
install -d -m 750 -o _owlproject -g owl-readmodel /var/lib/owlv/readmodel
_ok "owl-readmodel グループ・/var/lib/owlv/readmodel (owner=_owlproject, group読み取りのみ)"

# ── ForceCommand ラッパー ─────────────────────────────────
# 運用ユーザーがSSH接続すると owlv-app として owlv が直接起動し、exit = SSH切断。
# OWLV_ROOT_ADMIN_USERNAME は doas.conf の setenv で owlv-app プロセスへ引き継がれる
# (doc/user.md §7: このユーザー名で SSH した時だけ Admin を自動生成する)。
_log "owl-session ForceCommand ラッパーを配置"
cat >/usr/local/bin/owl-session <<'WRAPPER'
#!/bin/sh
# owlv-app として実行されると実ユーザーは owlv-app になり、本人の身元が消える。
# doas.conf の setenv 指定で OWLV_SSH_USER だけを明示的に引き継ぐ
# (sudo の SUDO_USER と同じ考え方; doc/user.md §4.1)。
OWLV_SSH_USER="$(id -un)"
export OWLV_SSH_USER
[ -r /etc/owlv/owlv.env ] && . /etc/owlv/owlv.env
export OWLV_ROOT_ADMIN_USERNAME
# DB 接続情報 (PG*) は owlv-app 自身が所有する /etc/owlv/db.env から
# owlv-app-run (doas 先) が読む — 操作者(本人)の権限では読めない設計に
# しているため、ここ (owl-session, 本人の uid で実行中) では一切触れない。
exec doas -u owlv-app /usr/local/libexec/owlv-app-run
WRAPPER
chmod 755 /usr/local/bin/owl-session
_ok "owl-session 配置"

# ── owl-user-sync: OS アカウント同期ヘルパー (doc/user.md §3.1) ──────
# owlv アプリ内のユーザーマスタ(Core.Domain.User)からの一方向プロジェクション。
# --apply: useradd/usermod/userdel・authorized_keys を冪等に適用する。
# --observe: 生の事実(uid/shell/groups/鍵)をJSONで報告するだけ。成功/失敗の
#   判定はしない — Shell.Interpreters.UserOsSync がここで得た事実を
#   望ましい状態と独立に突合する ("スクリプトの自己申告を信じない" 方針)。
_log "owl-user-sync を配置"
cat >/usr/local/sbin/owl-user-sync <<'SCRIPT'
#!/bin/sh
# owl-user-sync --apply '<json>' | --observe <username>
set -eu

_die() { echo "owl-user-sync: $*" >&2; exit 1; }

_json_field() {
	# 超簡易 JSON フィールド抽出 (依存パッケージを増やさないための割り切り)。
	# 入力フォーマットは owlv-app 側 (aeson) が生成する固定キー順を前提とする。
	printf '%s' "$1" | sed -n "s/.*\"$2\":\"\\?\\([^\",}]*\\)\"\\?.*/\\1/p" | head -1
}

case "${1:-}" in
--apply)
	json="${2:?json required}"
	username=$(_json_field "$json" username)
	uid=$(_json_field "$json" uid)
	role=$(_json_field "$json" role)
	status=$(_json_field "$json" status)
	[ -n "$username" ] || _die "username が空"

	case "$role" in
	Operator) group=owl-operators shell=/sbin/nologin ;;
	Maintainer) group=owl-maintainers shell=/bin/ksh ;;
	Admin) group=owl-maintainers shell=/bin/ksh ;;
	*) _die "未知の role: $role" ;;
	esac

	case "$status" in
	Removed)
		id "$username" >/dev/null 2>&1 && userdel -r "$username" || true
		exit 0
		;;
	esac

	if id "$username" >/dev/null 2>&1; then
		usermod -G "$group" -s "$shell" "$username"
	else
		useradd -u "$uid" -m -G "$group" -s "$shell" "$username"
	fi
	install -d -m 700 "/home/$username/.ssh"
	chown "$username:$group" "/home/$username/.ssh"

	if [ "$status" = "Suspended" ]; then
		usermod -L "$username" 2>/dev/null || true
		: >"/home/$username/.ssh/authorized_keys"
	else
		usermod -U "$username" 2>/dev/null || true
		# ssh_keys 配列を1行1鍵で authorized_keys に書き出す
		printf '%s' "$json" |
			sed -n 's/.*"ssh_keys":\[\(.*\)\].*/\1/p' |
			tr ',' '\n' | sed 's/^"//; s/"$//' |
			grep -v '^$' >"/home/$username/.ssh/authorized_keys" || true
	fi
	chmod 600 "/home/$username/.ssh/authorized_keys"
	chown "$username:$group" "/home/$username/.ssh/authorized_keys"
	;;
--observe)
	username="${2:?username required}"
	if ! id "$username" >/dev/null 2>&1; then
		echo '{"exists":false,"uid":null,"shell":null,"groups":[],"ssh_keys":[]}'
		exit 0
	fi
	uid=$(id -u "$username")
	shell=$(awk -F: -v u="$username" '$1==u{print $7}' /etc/passwd)
	groups=$(id -Gn "$username" | tr ' ' ',' | sed 's/[^,]*/"&"/g')
	keysfile="/home/$username/.ssh/authorized_keys"
	if [ -r "$keysfile" ]; then
		keys=$(sed 's/.*/"&"/' "$keysfile" | paste -sd, -)
	else
		keys=""
	fi
	printf '{"exists":true,"uid":%s,"shell":"%s","groups":[%s],"ssh_keys":[%s]}\n' \
		"$uid" "$shell" "$groups" "$keys"
	;;
*)
	_die "usage: owl-user-sync --apply <json> | --observe <username>"
	;;
esac
SCRIPT
chmod 755 /usr/local/sbin/owl-user-sync
_ok "owl-user-sync 配置"

# ── doas: owlv-app のみ owl-user-sync を呼べる。各 OS アカウント自身には何も許可しない ──
_log "doas.conf にユーザー同期権限を追加"
# Hop1 (operator/maintainer → owlv-app): 本人識別用の OWLV_SSH_USER と
# ブートストラップ用の OWLV_ROOT_ADMIN_USERNAME だけ引き継ぐ。
DOAS_LINE_SESSION="permit nopass :owl-operators as owlv-app setenv { OWLV_SSH_USER OWLV_ROOT_ADMIN_USERNAME } cmd /usr/local/libexec/owlv-app-run"
DOAS_LINE_SESSION2="permit nopass :owl-maintainers as owlv-app setenv { OWLV_SSH_USER OWLV_ROOT_ADMIN_USERNAME } cmd /usr/local/libexec/owlv-app-run"
# Hop2 (owlv-app → root): owl-user-sync 一本だけ。setenv は不要 (JSON 引数で受け渡す)。
DOAS_LINE_SYNC="permit nopass owlv-app cmd /usr/local/sbin/owl-user-sync"
for line in "$DOAS_LINE_SESSION" "$DOAS_LINE_SESSION2" "$DOAS_LINE_SYNC"; do
	grep -qF "$line" /etc/doas.conf 2>/dev/null || echo "$line" >>/etc/doas.conf
done
_ok "doas.conf 更新"

# ── OWLV_ROOT_ADMIN_USERNAME の引き継ぎ ───────────────────────────────────
# provision.sh が owl-config.toml [user] root_admin_username を環境変数で注入する。
# owlv-app の起動環境にも setenv で渡るよう doas.conf に明記する (上記)。
if [ -n "$ROOT_ADMIN_USERNAME" ]; then
	install -d -m 750 /etc/owlv
	printf 'OWLV_ROOT_ADMIN_USERNAME=%s\n' "$ROOT_ADMIN_USERNAME" >/etc/owlv/owlv.env
	# 640 (root:wheel) だと owl-session (操作者本人の uid で実行中) から
	# 読めず、OWLV_ROOT_ADMIN_USERNAME が常に未設定になっていた
	# (実際に発生: [ -r ... ] が false になり無言でスキップされる)。
	# 値はユーザー名のみで機密性が無いため world-readable で問題ない。
	chmod 644 /etc/owlv/owlv.env
	_ok "OWLV_ROOT_ADMIN_USERNAME=${ROOT_ADMIN_USERNAME} を /etc/owlv/owlv.env に記録 (644)"
else
	_info "警告: OWLV_ROOT_ADMIN_USERNAME 未設定。最初の Admin を自動生成できません。"
fi

# OWLV_ROOT_ADMIN_USERNAME の OS アカウントは owl-user-sync の管轄外（鶏卵問題、
# doc/user.md §7）。AP VM 上に手動で作成し owl-maintainers に入れておくこと:
#   useradd -m -G owl-maintainers -s /bin/ksh "${ROOT_ADMIN_USERNAME:-<root_admin_username>}"
#   install -d -m 700 /home/<user>/.ssh && vi /home/<user>/.ssh/authorized_keys
# このユーザーで SSH すると owlv が Admin/Active な User を自動生成する。

# ── SSH 設定 ──────────────────────────────────────────────
# sshd_config.d パターン: 繰り返し実行してもファイルを上書きするだけ
_log "SSH 設定"

grep -qF 'Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config ||
	echo 'Include /etc/ssh/sshd_config.d/*.conf' >>/etc/ssh/sshd_config

install -d /etc/ssh/sshd_config.d

cat >/etc/ssh/sshd_config.d/owl.conf <<EOF
Port ${APP_SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
AllowGroups owl-operators owl-maintainers

# 運用グループ: owlv を直接起動、シェルアクセスを禁止
# PermitTTY yes は既定値だが、Brick の描画には PTY 割り当てが必須であり、
# ForceCommand によるシェル到達禁止と PTY 許可が別軸であることを明示するため
# 意図を込めて明記する (dev_sec_ops.md §1.2)。
Match Group owl-operators
    ForceCommand /usr/local/bin/owl-session
    PermitTTY yes
    AllowAgentForwarding no
    AllowTcpForwarding no
    PermitTunnel no
    X11Forwarding no
    PermitEmptyPasswords no

# 保守グループ: 通常の ksh シェル、転送は禁止
Match Group owl-maintainers
    PermitTTY yes
    AllowAgentForwarding no
    AllowTcpForwarding no
    PermitTunnel no
    X11Forwarding no
    PermitEmptyPasswords no
EOF

sshd -t || _die "sshd_config の構文エラー"
rcctl enable sshd
rcctl restart sshd
_ok "SSH 設定 (ポート ${APP_SSH_PORT})"

# ── DB 接続環境変数テンプレート ───────────────────────────
# Shell.EventStore.connectDb は標準 libpq 環境変数 (PGHOST 等) しか読まない。
# 旧版はここを独自命名 (OWL_DB_*) で書いていたため、何にも読まれない
# 死んだ設定になっていた (実際に発生)。doc/cqrs.md の db-projector.env と
# 同じ PG* 命名に統一する。
_log "DB 接続環境変数テンプレートを配置"
install -d -m 750 /etc/owl
cat >/etc/owlv/db.env.template <<EOF
# /etc/owlv/db.env.template — owlv-app 専用 (owlv-app-run が source する)
# db-secrets-rotate.sh が実値で /etc/owlv/db.env (chmod 600, owner owlv-app) を生成する。
PGHOST=${OWL_DB_IP}
PGPORT=5432
PGDATABASE=${DB_NAME}
PGUSER=${DB_APP_USER}
PGPASSWORD=<手動設定>
PGSSLMODE=verify-full
PGSSLROOTCERT=/etc/owlv/db-ca.crt
EOF
chmod 640 /etc/owlv/db.env.template
chown owlv-app /etc/owlv/db.env.template
_ok "DB 接続テンプレート: /etc/owlv/db.env.template"

# ── owlv-app-run: doas 先のラッパー (DB 接続情報を owlv-app 権限で読む) ──
# doas は doas.conf に明記した変数しか転送しない (env_reset 相当) ため、
# 操作者本人の uid (owl-session) で /etc/owlv/db.env を source しても doas越しに
# は伝わらない。さらに db.env を操作者から読める権限にすると秘密情報が
# 漏れる。doas の cmd ターゲット自体をこのラッパーにし、owlv-app に
# 切り替わった後 (= db.env を所有者権限で読める状態) で source してから
# 実バイナリを exec する — rc.d/owlv_projector と同じ「source-then-exec」
# パターン (doc/cqrs.md)。
_log "owlv-app-run ラッパーを配置"
install -d -m 755 /usr/local/libexec
cat >/usr/local/libexec/owlv-app-run <<'WRAPPER'
#!/bin/sh
set -eu
[ -r /etc/owlv/db.env ] && . /etc/owlv/db.env
export PGHOST PGPORT PGDATABASE PGUSER PGPASSWORD PGSSLMODE PGSSLROOTCERT
exec /usr/local/bin/owlv-app
WRAPPER
chmod 555 /usr/local/libexec/owlv-app-run
chown root:bin /usr/local/libexec/owlv-app-run
_ok "owlv-app-run 配置"

# ── owlv-projector 専用 DB 接続情報 (doc/cqrs.md §8) ─────────────────
# owl-app の db.env (OWL_DB_* というアプリ独自の変数名) とは違い、ここは
# 標準 libpq 変数名 (PG*) で書く — rc.d スクリプトがこのファイルをそのまま
# source して owlv-projector を直接 exec するため (owl-session のような
# ラッパーを経由しないデーモン起動)。パスワードは db-secrets-rotate.sh が
# 実値で上書きするまでのプレースホルダー。
_log "owlv-projector 用 DB 接続テンプレートを配置"
cat >/etc/owlv/db-projector.env.template <<EOF
# /etc/owlv/db-projector.env.template — owlv-projector 専用 (doc/cqrs.md §8)
# db-secrets-rotate.sh が実値で /etc/owlv/db-projector.env (chmod 600) を生成する。
PGHOST=${OWL_DB_IP}
PGPORT=5432
PGDATABASE=${DB_NAME}
PGUSER=${DB_PROJECTOR_USER}
PGPASSWORD=<手動設定>
PGSSLMODE=verify-full
PGSSLROOTCERT=/etc/owlv/db-ca.crt
EOF
chmod 640 /etc/owlv/db-projector.env.template
chown _owlproject /etc/owlv/db-projector.env.template
_ok "DB 接続テンプレート (projector): /etc/owlv/db-projector.env.template"

# ── owlv バイナリのプレースホルダー ───────────────────────
# 実際のバイナリは owl-control.sh deploy <tag> でインストールされる
if [ ! -f /usr/local/bin/owlv-app ]; then
	cat >/usr/local/bin/owlv-app <<'STUB'
#!/bin/sh
echo "owlv はまだインストールされていません。"
echo "ホストで: doas owl-control.sh deploy <vX.Y.Z>"
exit 1
STUB
	chmod 755 /usr/local/bin/owlv-app
	_info "owlv スタブを配置 (deploy コマンドで上書き)"
fi

if [ ! -f /usr/local/bin/owlv-projector ]; then
	cat >/usr/local/bin/owlv-projector <<'STUB'
#!/bin/sh
echo "owlv-projector はまだインストールされていません。"
echo "ホストで: doas owl-control.sh deploy <vX.Y.Z>"
exit 1
STUB
	chmod 755 /usr/local/bin/owlv-projector
	_info "owlv-projector スタブを配置 (deploy コマンドで上書き)"
fi

# ── owlv-projector rc.d サービス (doc/cqrs.md §3) ────────────────────
# rc.subr の daemon_user は su -fl (ログインシェル) でユーザーを切り替えるため
# db-projector.env の PG* 環境変数が失われる (実測済み・vm-git/vm-build の
# su -m 使用箇所と同じ理由)。daemon_user は使わず、rc_start を上書きして
# 自前で su -m (環境保持) を行う。
_log "owlv-projector rc.d サービスを登録"
cat >/etc/rc.d/owlv_projector <<'EOF'
#!/bin/ksh
daemon="/usr/local/bin/owlv-projector"
daemon_flags="run"
daemon_logger="daemon.info"
# owlv-projector run はフォアグラウンドで動き続け、自分自身をdetachしない
# (vm-git/vm-build の forgejo/forgejo-runner と同種の理由。rc_bg が無いと
# rc.subr が detach 待ちで daemon_timeout 一杯まで失敗する)。
rc_bg="YES"

. /etc/rc.d/rc.subr

rc_start() {
	${rcexec} "su -m _owlproject -c '. /etc/owlv/db-projector.env && exec ${daemon} ${daemon_flags}'"
}

rc_cmd "$1"
EOF
chmod 755 /etc/rc.d/owlv_projector
rcctl enable owlv_projector
_ok "owlv-projector rc.d サービス登録 (db-secrets-rotate.sh 完了後に起動すること)"

_log "AP VM セットアップ完了"
echo ""
echo " 【次のステップ】"
echo "   1. 運用ユーザー追加: doas add-owl-operator <username>"
echo "   2. 保守ユーザー追加: doas add-owl-maintainer <username>"
echo "   3. owlv デプロイ: (ホストから) doas owl-control.sh deploy vX.Y.Z"
echo "   4. DB シークレットローテーション (ホストから、本番封鎖後に一度):"
echo "      doas host/security/db-secrets-rotate.sh"
echo "      → db.env / db-projector.env が実値で生成され (db.env.template /"
echo "        db-projector.env.template から自動生成。手動コピーは不要)、"
echo "        db-ca.crt も配置され、owlv_projector が自動的に再起動される。"
echo "        db.env 生成まで owlv-app は DB に接続できない (それまでは想定通り)。"
