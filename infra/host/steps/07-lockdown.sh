# shellcheck shell=ksh
# step 07 — 本番封鎖
_step 7 "本番封鎖"

# DHCP / HTTP プロビジョニングサーバーを停止
_log "DHCP / HTTP プロビジョニングサーバーを停止..."
rcctl stop dhcpd 2>/dev/null || true
rcctl stop httpd 2>/dev/null || true
rcctl disable dhcpd 2>/dev/null || true
rcctl disable httpd 2>/dev/null || true
rm -rf /var/www/htdocs/sets
rm -f /var/www/htdocs/install.conf /tmp/dhcpd-prov.conf /tmp/httpd-prov.conf
_ok "プロビジョニングサーバー停止"

# プロビジョニング用の使い捨て鍵を削除
_log "プロビジョニング SSH 鍵を削除: ${PROV_KEY}"
rm -f "$PROV_KEY" "${PROV_KEY}.pub"
_ok "プロビジョニング SSH 鍵削除"

# IP フォワーディング無効化 + 本番 PF ルール適用
# sshd は pf.conf で通過させているのでロックアウトしない
# Yubikey 未着のため pf.conf の SSH pass ルールは現時点で有効
_log "IP フォワーディングを無効化..."
sysctl net.inet.ip.forwarding=0
_log "本番 pf.conf を配置して適用..."
install -m 600 "${SELF}/host/conf/pf.conf" /etc/pf.conf
install -m 644 "${SELF}/host/conf/rc.conf.local" /etc/rc.conf.local
pfctl -f /etc/pf.conf
_log "pfctl -s rules:"
pfctl -s rules 2>/dev/null | while read -r l; do _log "  $l"; done
_ok "本番 PF 適用 (NAT 解除・封鎖)"

# 改ざん検知ベースライン記録 (§5)
_log "改ざん検知ベースラインを計算中..."
find /etc /usr/local/sbin -type f 2>/dev/null | sort |
	xargs sha256 >/etc/owl/integrity-baseline.sha256
_log "ベースライン: $(wc -l </etc/owl/integrity-baseline.sha256) ファイルを記録"
_ok "改ざん検知ベースライン記録"

# age 受信者公開鍵の確認
if [ ! -f "$(_toml "dr" "age_pubkey_file")" ]; then
	_info ""
	_info "⚠  age 受信者公開鍵が未配置です。DR 射出を有効にするには:"
	_info "   エスクロー (§2.3) から公開鍵を取り出し、以下に配置してください:"
	_info "   $(_toml "dr" "age_pubkey_file")"
fi
