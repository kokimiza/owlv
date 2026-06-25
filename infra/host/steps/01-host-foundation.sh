# shellcheck shell=ksh
# step 01 — ホスト基盤セットアップ
# ネットワーク (WAN 正規化は STEP 2, vmd/仮想化基盤は STEP 3) には関与しない。
# VM 構成に依存しない、ホスト OS 側の汎用セットアップのみを扱う。
_step 1 "ホスト基盤セットアップ"

install -d -m 750 /etc/owlv
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
# curl は owl-control.sh の deploy-poll / sign-poll が Forgejo API (JSON POST/PATCH)
# を叩くために必須 (OpenBSD base の ftp(1) では任意ヘッダ付き POST が困難なため)。
pkg_add age rclone curl 2>/dev/null && _ok "age / rclone / curl インストール" ||
	_info "警告: age / rclone / curl の自動インストール失敗。後で手動実行: pkg_add age rclone curl"

# ── リリース署名鍵 (signify, doc/dev_sec_ops.md §4.2) ─────────────
# 【信頼の根はホストに置く】Build VM は push/PR という外部入力を直接処理する
# Forgejo Runner の実行環境であり、攻撃面が最も広い。秘密鍵を Build VM に
# 置くと、Build VM 侵害時に攻撃者が改ざんバイナリへ正規の署名を付与できてしまい
# 「成果物改ざんは署名検証で検出される」という前提が崩壊する。そのためホスト
# OS が秘密鍵を排他的に保持し、owl-control.sh sign-poll(cron 経由、5分間隔)が
# Git VM 内の未署名リリースを検知して署名する。公開鍵は AP VM の
# /etc/owlv/release-signify.pub へ手動配置する(age 受信者鍵と同様、最小経路)。
install -d -m 750 /etc/owlv
SIGNIFY_SEC=/etc/owlv/release-signify.sec
SIGNIFY_PUB=/etc/owlv/release-signify.pub
if [ ! -f "$SIGNIFY_SEC" ]; then
	_log "リリース署名鍵 (signify) をホスト上に生成"
	signify -G -n -p "$SIGNIFY_PUB" -s "$SIGNIFY_SEC" ||
		_die "signify 鍵の生成に失敗しました"
	chmod 600 "$SIGNIFY_SEC"
	chmod 644 "$SIGNIFY_PUB"
	_ok "signify 鍵をホストに生成: ${SIGNIFY_PUB}"
	_info "AP VM の /etc/owlv/release-signify.pub へ以下を配置してください:"
	cat "$SIGNIFY_PUB"
else
	_info "signify 鍵: 既存のためスキップ"
fi

# ── syslog の Audit VM への一方通行転送 (§5, §6.1 鉄則②) ──────────
# auth ファシリティ(su/sudo・sshd ログイン成否・owl-integrity-check.sh の
# 改ざん検知アラート)のみを転送する。ドメインデータは元々ホスト上に存在しない
# ためマスキング処理は不要だが、転送対象を auth に絞ることで VM 側と同じ
# 「メタ情報のみ」の方針を統一する。Audit VM がまだ存在しない/起動していない
# 間は UDP の送り先が unreachable なだけで、fire-and-forget なので副作用はない。
grep -qF "@${OWL_AUDIT_IP}" /etc/syslog.conf 2>/dev/null || {
	printf 'auth.*\t\t\t\t\t@%s\n' "${OWL_AUDIT_IP}" >>/etc/syslog.conf
	rcctl restart syslogd 2>/dev/null || true
	_ok "syslog.conf に Audit VM (${OWL_AUDIT_IP}) への auth.* 転送を追加"
}

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
# 転送をシグナル単位で禁止する。
#
# アカウント作成/更新/失効ロジックは host/security/dev-join.sh の sync に
# 一本化している (運用中に手動で叩く `dev-join.sh sync` と、provision 時の
# 処理を同じ実装にして冪等性・再現性を保つため)。.pub を置くだけで開発者を
# 追加でき、退職時は対応する .pub を削除して再実行すれば失効する。
GIT_JUMP_GROUP="owl-git-jump"
sh "${SELF}/host/security/dev-join.sh" sync

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
