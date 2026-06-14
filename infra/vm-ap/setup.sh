#!/bin/sh
# vm-ap/setup.sh — AP VM セットアップ (owlv TUI アプリケーション)
# §1.4: 運用グループはシェルなし、owlv が直接起動される
# §3.1: Forgejo レジストリからバイナリを取得してインストール
# 実行: provision.sh の STEP 6 から SSH で呼び出す
set -eu

_log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die()  { _log "エラー: $*" >&2; exit 1; }
_info() { _log "    $*"; }
_ok()   { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"

# 環境変数 (provision.sh から注入される)
OWL_AP_IP="${OWL_AP_IP:?OWL_AP_IP is required}"
OWL_DB_IP="${OWL_DB_IP:?OWL_DB_IP is required}"
GIT_IP="${OWL_GIT_IP:?OWL_GIT_IP is required}"
APP_SSH_PORT="${APP_SSH_PORT:-8022}"

_log "AP VM セットアップ開始 (${OWL_AP_IP})"

# ── パッケージ ────────────────────────────────────────────
_log "パッケージインストール"
pkg_add -x bash 2>/dev/null || true   # owlv は ksh/sh で動作するが念のため
_ok "パッケージ"

# ── ユーザー・グループ ─────────────────────────────────────
_log "グループ・ユーザー設定"

groupadd owl-operators  2>/dev/null || true
groupadd owl-maintainers 2>/dev/null || true

# owl-operators: ForceCommand によりシェルを触れない
# owl-maintainers: 通常の ksh シェル + sudo 相当の権限なし (参照専用の保守者)

_ok "グループ作成 (owl-operators / owl-maintainers)"

# ── ForceCommand ラッパー ─────────────────────────────────
# 運用ユーザーがSSH接続するとowlvが直接起動し、exit = SSH切断
_log "owl-session ForceCommand ラッパーを配置"
cat > /usr/local/bin/owl-session <<'WRAPPER'
#!/bin/sh
# DB 接続情報を環境変数から注入 (/etc/owl/db.env がある場合)
[ -r /etc/owl/db.env ] && . /etc/owl/db.env
exec /usr/local/bin/owl-app
WRAPPER
chmod 755 /usr/local/bin/owl-session
_ok "owl-session 配置"

# ── ユーザー追加スクリプト ────────────────────────────────
_log "ユーザー管理スクリプトを配置"

# add-owl-operator: nologin シェル、owl-operators グループ
cat > /usr/local/sbin/add-owl-operator <<'SCRIPT'
#!/bin/sh
[ -n "$1" ] || { echo "usage: add-owl-operator <username>"; exit 1; }
useradd -m -G owl-operators -s /sbin/nologin "$1"
install -d -m 700 "/home/$1/.ssh"
chown "$1:owl-operators" "/home/$1/.ssh"
echo "ユーザー $1 を owl-operators に追加しました"
echo "authorized_keys を設定してください:"
echo "  vi /home/$1/.ssh/authorized_keys"
echo "  chmod 600 /home/$1/.ssh/authorized_keys"
echo "  chown $1 /home/$1/.ssh/authorized_keys"
SCRIPT
chmod 755 /usr/local/sbin/add-owl-operator

# add-owl-maintainer: ksh シェル、owl-maintainers グループ
cat > /usr/local/sbin/add-owl-maintainer <<'SCRIPT'
#!/bin/sh
[ -n "$1" ] || { echo "usage: add-owl-maintainer <username>"; exit 1; }
useradd -m -G owl-maintainers -s /bin/ksh "$1"
install -d -m 700 "/home/$1/.ssh"
chown "$1:owl-maintainers" "/home/$1/.ssh"
echo "ユーザー $1 を owl-maintainers に追加しました"
echo "authorized_keys を設定してください:"
echo "  vi /home/$1/.ssh/authorized_keys"
echo "  chmod 600 /home/$1/.ssh/authorized_keys"
echo "  chown $1 /home/$1/.ssh/authorized_keys"
SCRIPT
chmod 755 /usr/local/sbin/add-owl-maintainer

_ok "ユーザー管理スクリプト配置"

# ── SSH 設定 ──────────────────────────────────────────────
# sshd_config.d パターン: 繰り返し実行してもファイルを上書きするだけ
_log "SSH 設定"

grep -qF 'Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config || \
    echo 'Include /etc/ssh/sshd_config.d/*.conf' >> /etc/ssh/sshd_config

install -d /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/owl.conf <<EOF
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
cat > /etc/owl/db.env.template <<EOF
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
    cat > /usr/local/bin/owl-app <<'STUB'
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
