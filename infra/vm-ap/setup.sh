#!/bin/sh
# vm-ap/setup.sh — AP VM セットアップ (owlv TUI アプリケーション)
# §1.4: 運用グループはシェルなし、owlv が直接起動される
# §3.1: Forgejo レジストリからバイナリを取得してインストール
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

# 環境変数 (provision.sh から注入される)
OWL_AP_IP="${OWL_AP_IP:?OWL_AP_IP is required}"
OWL_DB_IP="${OWL_DB_IP:?OWL_DB_IP is required}"
GIT_IP="${OWL_GIT_IP:?OWL_GIT_IP is required}"
APP_SSH_PORT="${APP_SSH_PORT:-8022}"

# .claude/user.md §7: Admin を自動生成してよい唯一のOSユーザー名 (owl-config.toml [user])
ROOT_ADMIN_USERNAME="${OWLV_ROOT_ADMIN_USERNAME:-}"

_log "AP VM セットアップ開始 (${OWL_AP_IP})"

# ── パッケージ ────────────────────────────────────────────
_log "パッケージインストール"
pkg_add -x bash 2>/dev/null || true # owlv は ksh/sh で動作するが念のため
_ok "パッケージ"

# ── ユーザー・グループ (.claude/user.md §2/§3) ──────────────────────────
_log "グループ・ユーザー設定"

groupadd owl-operators 2>/dev/null || true
groupadd owl-maintainers 2>/dev/null || true

# owl-operators: ForceCommand によりシェルを触れない
# owl-maintainers: 通常の ksh シェル + sudo 相当の権限なし (参照専用の保守者)
_ok "グループ作成 (owl-operators / owl-maintainers)"

# owl-app: owlv 本体を実際に動かす専用サービスアカウント。
# 接続してきた本人(alice 等)の OS アカウントには doas 権限を一切与えない —
# 昇格できるのは owl-app だけ、かつ owl-app が呼べるのは owl-user-sync 一本だけ
# (.claude/user.md §3.2: cron_batch.md の _owlbatch と同じゼロ権限委譲パターン)。
id owl-app >/dev/null 2>&1 || useradd -s /sbin/nologin -d /nonexistent owl-app
_ok "owl-app サービスアカウント"

# ── ForceCommand ラッパー ─────────────────────────────────
# 運用ユーザーがSSH接続すると owl-app として owlv が直接起動し、exit = SSH切断。
# OWLV_ROOT_ADMIN_USERNAME は doas.conf の setenv で owl-app プロセスへ引き継がれる
# (.claude/user.md §7: このユーザー名で SSH した時だけ Admin を自動生成する)。
_log "owl-session ForceCommand ラッパーを配置"
cat >/usr/local/bin/owl-session <<'WRAPPER'
#!/bin/sh
# owl-app として実行されると実ユーザーは owl-app になり、本人の身元が消える。
# doas.conf の setenv 指定で OWLV_SSH_USER だけを明示的に引き継ぐ
# (sudo の SUDO_USER と同じ考え方; .claude/user.md §4.1)。
OWLV_SSH_USER="$(id -un)"
export OWLV_SSH_USER
[ -r /etc/owl/owlv.env ] && . /etc/owl/owlv.env
export OWLV_ROOT_ADMIN_USERNAME
exec doas -u owl-app /usr/local/bin/owl-app
WRAPPER
chmod 755 /usr/local/bin/owl-session
_ok "owl-session 配置"

# ── owl-user-sync: OS アカウント同期ヘルパー (.claude/user.md §3.1) ──────
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
	# 入力フォーマットは owl-app 側 (aeson) が生成する固定キー順を前提とする。
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

# ── doas: owl-app のみ owl-user-sync を呼べる。各 OS アカウント自身には何も許可しない ──
_log "doas.conf にユーザー同期権限を追加"
# Hop1 (operator/maintainer → owl-app): 本人識別用の OWLV_SSH_USER と
# ブートストラップ用の OWLV_ROOT_ADMIN_USERNAME だけ引き継ぐ。
DOAS_LINE_SESSION="permit nopass :owl-operators as owl-app setenv { OWLV_SSH_USER OWLV_ROOT_ADMIN_USERNAME } cmd /usr/local/bin/owl-app"
DOAS_LINE_SESSION2="permit nopass :owl-maintainers as owl-app setenv { OWLV_SSH_USER OWLV_ROOT_ADMIN_USERNAME } cmd /usr/local/bin/owl-app"
# Hop2 (owl-app → root): owl-user-sync 一本だけ。setenv は不要 (JSON 引数で受け渡す)。
DOAS_LINE_SYNC="permit nopass owl-app cmd /usr/local/sbin/owl-user-sync"
for line in "$DOAS_LINE_SESSION" "$DOAS_LINE_SESSION2" "$DOAS_LINE_SYNC"; do
	grep -qF "$line" /etc/doas.conf 2>/dev/null || echo "$line" >>/etc/doas.conf
done
_ok "doas.conf 更新"

# ── OWLV_ROOT_ADMIN_USERNAME の引き継ぎ ───────────────────────────────────
# provision.sh が owl-config.toml [user] root_admin_username を環境変数で注入する。
# owl-app の起動環境にも setenv で渡るよう doas.conf に明記する (上記)。
if [ -n "$ROOT_ADMIN_USERNAME" ]; then
	install -d -m 750 /etc/owl
	printf 'OWLV_ROOT_ADMIN_USERNAME=%s\n' "$ROOT_ADMIN_USERNAME" >/etc/owl/owlv.env
	chmod 640 /etc/owl/owlv.env
	_ok "OWLV_ROOT_ADMIN_USERNAME=${ROOT_ADMIN_USERNAME} を /etc/owl/owlv.env に記録"
else
	_info "警告: OWLV_ROOT_ADMIN_USERNAME 未設定。最初の Admin を自動生成できません。"
fi

# OWLV_ROOT_ADMIN_USERNAME の OS アカウントは owl-user-sync の管轄外（鶏卵問題、
# .claude/user.md §7）。AP VM 上に手動で作成し owl-maintainers に入れておくこと:
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
Match Group owl-operators
    ForceCommand /usr/local/bin/owl-session
    AllowAgentForwarding no
    AllowTcpForwarding no
    PermitTunnel no
    X11Forwarding no
    PermitEmptyPasswords no

# 保守グループ: 通常の ksh シェル、転送は禁止
Match Group owl-maintainers
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
_log "DB 接続環境変数テンプレートを配置"
install -d -m 750 /etc/owl
cat >/etc/owl/db.env.template <<EOF
# /etc/owl/db.env — DB 接続情報 (手動で記入後 db.env にコピー)
# chmod 640 /etc/owl/db.env
OWL_DB_HOST=${OWL_DB_IP}
OWL_DB_PORT=5432
OWL_DB_NAME=owl
OWL_DB_USER=owl_app
OWL_DB_PASS=<手動設定>
OWL_DB_SSLMODE=verify-full
OWL_DB_SSLROOTCERT=/etc/owl/db-ca.crt
EOF
_ok "DB 接続テンプレート: /etc/owl/db.env.template"

# ── owlv バイナリのプレースホルダー ───────────────────────
# 実際のバイナリは owl-control.sh deploy <tag> でインストールされる
if [ ! -f /usr/local/bin/owl-app ]; then
	cat >/usr/local/bin/owl-app <<'STUB'
#!/bin/sh
echo "owlv はまだインストールされていません。"
echo "ホストで: doas owl-control.sh deploy <vX.Y.Z>"
exit 1
STUB
	chmod 755 /usr/local/bin/owl-app
	_info "owlv スタブを配置 (deploy コマンドで上書き)"
fi

_log "AP VM セットアップ完了"
echo ""
echo " 【次のステップ】"
echo "   1. 運用ユーザー追加: doas add-owl-operator <username>"
echo "   2. 保守ユーザー追加: doas add-owl-maintainer <username>"
echo "   3. DB 接続情報設定: cp /etc/owl/db.env.template /etc/owl/db.env && vi /etc/owl/db.env"
echo "   4. owlv デプロイ: (ホストから) doas owl-control.sh deploy vX.Y.Z"
