# shellcheck shell=ksh
# step 09 — 本番封鎖
_step 9 "本番封鎖"

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

# IP フォワーディングは無効化しない。AP VM → Git VM (10.0.1.10 → 10.0.2.10) や
# 各 VM → Audit VM (→ 10.0.3.10) はいずれも異なる仮想スイッチ(=異なる L3 サブネット)
# 間の通信であり、ホストによる IP ルーティングなしには成立しない。無効化すると
# pf のルール自体は正しくてもルーティング層で先に落ちるため、AP VM → Git VM の
# デプロイ取得や VM → Audit VM の syslog 転送が無音のまま機能しなくなる。許可範囲は
# pf.conf の default-deny + 個別 pass で制御するため、フォワーディングは有効のまま
# 本番封鎖する。再起動後も有効になるよう /etc/sysctl.conf にも永続化する。
# (sshd は pf.conf で通過させているのでロックアウトしない。Yubikey 未着のため
# pf.conf の SSH pass ルールは現時点で有効)
_log "IP フォワーディングを有効化 (永続化)..."
sysctl net.inet.ip.forwarding=1
sed -i '/^# owl-forwarding sysctl$/,$d' /etc/sysctl.conf 2>/dev/null || true
{
	echo "# owl-forwarding sysctl"
	echo "net.inet.ip.forwarding=1"
} >>/etc/sysctl.conf

# Audit VM 通知先ホワイトリスト (§6.1 鉄則③) — owl-config.toml の
# [audit].notify_dest_cidrs から pf の table ファイルを生成する。webhook URL が
# 未確定で空配列のままなら空ファイル = audit_lan の外向き443は全遮断のまま
# (安全側デフォルト)。DNS の動的解決はしない。
_log "Audit VM 通知先ホワイトリストを生成..."
_AUDIT_CIDRS_RAW="$(_toml "audit" "notify_dest_cidrs")"
{
	echo "# owl-audit-notify-dst — owl-config.toml [audit].notify_dest_cidrs から生成"
	echo "# webhook URL 確定後にプロバイダ公式 CIDR を追記して再生成すること"
	printf '%s' "$_AUDIT_CIDRS_RAW" | tr -d '[]" ' | tr ',' '\n' | while read -r _cidr; do
		[ -n "$_cidr" ] && echo "$_cidr"
	done
} >/etc/owlv/audit-notify-dst.conf
chmod 644 /etc/owlv/audit-notify-dst.conf
_log "  $(grep -vc '^#' /etc/owlv/audit-notify-dst.conf 2>/dev/null || echo 0) 件の CIDR を登録"

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
	xargs sha256 >/etc/owlv/integrity-baseline.sha256
_log "ベースライン: $(wc -l </etc/owlv/integrity-baseline.sha256) ファイルを記録"
_ok "改ざん検知ベースライン記録"

# age 受信者公開鍵の確認
if [ ! -f "$(_toml "dr" "age_pubkey_file")" ]; then
	_info ""
	_info "⚠  age 受信者公開鍵が未配置です。DR 射出を有効にするには:"
	_info "   エスクロー (§2.3) から公開鍵を取り出し、以下に配置してください:"
	_info "   $(_toml "dr" "age_pubkey_file")"
fi
