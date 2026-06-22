# shellcheck shell=ksh
# step 01 — ホスト基盤セットアップ
# ネットワーク (WAN 正規化は STEP 2, vmd/仮想化基盤は STEP 3) には関与しない。
# VM 構成に依存しない、ホスト OS 側の汎用セットアップのみを扱う。
_step 1 "ホスト基盤セットアップ"

install -d -m 750 /etc/owl
install -d -m 750 "$LOGDIR"

# 管理スクリプトを配置
install -m 700 "${SELF}/host/sbin/owl-control.sh" /usr/local/sbin/owl-control.sh
install -m 700 "${SELF}/host/sbin/owl-integrity-check.sh" /usr/local/sbin/owl-integrity-check.sh
install -m 700 "${SELF}/host/sbin/owl-pfctl-pinhole" /usr/local/sbin/owl-pfctl-pinhole

# known_hosts は provision が上書きできるよう初期化する
install -m 600 /dev/null /etc/owlv/known_hosts
_ok "管理スクリプト配置"

# 設定ファイルを配置 (doas.conf / newsyslog.conf / crontab)
# vmd.conf は STEP 7 (VM OS autoinstall) でディスクイメージ作成後に配置する (先に置くと起動失敗)
# pf.conf と rc.conf.local は STEP 9 の本番封鎖時に適用する
install -m 644 "${SELF}/host/conf/doas.conf" /etc/doas.conf
install -m 644 "${SELF}/host/conf/newsyslog.conf" /etc/newsyslog.conf
install -m 600 "${SELF}/host/conf/crontab" /etc/crontab
_ok "設定ファイル配置"

# owl-control 専用ユーザー
id owl-control >/dev/null 2>&1 || useradd -s /sbin/nologin -d /nonexistent owl-control

# 必要パッケージ (この時点では外向き通信が開いているので pkg_add で取得)
pkg_add age rclone 2>/dev/null && _ok "age / rclone インストール" ||
	_info "警告: age / rclone の自動インストール失敗。後で手動実行: pkg_add age rclone"

# vmm-bios (SeaBIOS) — /etc/firmware/vmm-bios が無いと vmctl start が
# "Cannot allocate memory" という誤った errno に化けて失敗する。
# 正規の取得方法: fw_update vmm (ドライバ名。vmm-firmware パッケージをインストール)
# etc79.tgz は OpenBSD 7.9 amd64 の配布物に存在しない (SHA256 に記載なし)。
if [ -f /etc/firmware/vmm-bios ]; then
	_ok "vmm-bios 既存 → スキップ"
else
	_log "/etc/firmware/vmm-bios が見つかりません — fw_update vmm で取得します..."
	if fw_update vmm; then
		_ok "fw_update vmm 完了 (vmm-firmware インストール済み)"
	else
		_die "fw_update vmm 失敗 — ネットワーク疎通と firmware.openbsd.org へのアクセスを確認してください"
	fi
	[ -f /etc/firmware/vmm-bios ] || _die "fw_update 後も /etc/firmware/vmm-bios が見つかりません"
fi
[ -r /etc/firmware/vmm-bios ] || _die "vmm-bios が読み取れません — 'fw_update vmm' を実行してください"
chmod 644 /etc/firmware/vmm-bios 2>/dev/null || true

# ── git push 用ジャンプアカウント (開発者ごと) ────────────────
# dev_lan (git_vm) は LAN から直接到達できない (エアギャップ設計)。
# 開発者は `ssh -J <user>@<host> git@git_vm` の踏み台としてのみホストを使う。
# シェルは与えず (ForceCommand /bin/false)、PermitOpen で git_vm:22 以外への
# 転送をシグナル単位で禁止する。鍵を置くだけで開発者を追加/削除でき、
# 退職時は対応する .pub を削除して再実行すれば失効する。
GIT_JUMP_KEYS_DIR="${SELF}/host/conf/git-jump-keys"
GIT_JUMP_GROUP="owl-git-jump"
install -d -m 755 "$GIT_JUMP_KEYS_DIR"
groupadd "$GIT_JUMP_GROUP" 2>/dev/null || true

_log "git-jump アカウントを同期 (${GIT_JUMP_KEYS_DIR}/*.pub)..."
_git_jump_n=0
for _pub in "${GIT_JUMP_KEYS_DIR}"/*.pub; do
	[ -f "$_pub" ] || continue
	_user="$(basename "$_pub" .pub)"
	if id "$_user" >/dev/null 2>&1; then
		usermod -G "$GIT_JUMP_GROUP" -s /sbin/nologin "$_user"
	else
		useradd -m -G "$GIT_JUMP_GROUP" -s /sbin/nologin "$_user"
	fi
	install -d -m 700 -o "$_user" -g "$GIT_JUMP_GROUP" "/home/${_user}/.ssh"
	install -m 600 -o "$_user" -g "$GIT_JUMP_GROUP" "$_pub" "/home/${_user}/.ssh/authorized_keys"
	_info "git-jump アカウント: ${_user}"
	_git_jump_n=$((_git_jump_n + 1))
done
[ "$_git_jump_n" -gt 0 ] || _info "鍵が見つかりません。追加するには ${GIT_JUMP_KEYS_DIR}/<user>.pub を配置してください"
_ok "git-jump アカウント同期 (${_git_jump_n} 件)"

# sshd_config.d パターン: 繰り返し実行してもファイルを上書きするだけ (vm-ap/setup.sh と同方針)
grep -qF 'Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config ||
	echo 'Include /etc/ssh/sshd_config.d/*.conf' >>/etc/ssh/sshd_config
install -d /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/git-jump.conf <<EOF
# owl-git-jump: シェル禁止、${OWL_GIT_IP}:22 (git push) / :3000 (Forgejo Web UI
# のローカルポートフォワード閲覧用) への転送のみ許可
Match Group ${GIT_JUMP_GROUP}
    ForceCommand /bin/false
    PermitTTY no
    X11Forwarding no
    AllowAgentForwarding no
    AllowTcpForwarding yes
    PermitOpen ${OWL_GIT_IP}:22 ${OWL_GIT_IP}:3000
    PermitEmptyPasswords no
EOF
chmod 600 /etc/ssh/sshd_config.d/git-jump.conf
rcctl reload sshd 2>/dev/null || rcctl restart sshd
_ok "sshd_config.d/git-jump.conf 配置 + sshd reload"
