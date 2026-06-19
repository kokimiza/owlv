# shellcheck shell=ksh
# step 02 — WAN ネットワーク正規化
_step 2 "WAN ネットワーク正規化"

# ── WAN (${WAN_IF}) 正規化 ────────────────────────────────────
# OpenBSD 手動インストール時、ネットワーク設定で一度 "autoconf" (DHCP) を
# 選んで疎通確認し、その後 SSH 用に静的 IP を追記すると、
# /etc/hostname.${WAN_IF} に "inet autoconf" と静的 "inet x.x.x.x" の両方が
# 残ったままになる。dhcpleased がリースを握り続けるため WAN_IF に 2 つ目の
# IPv4 が付き、STEP 4 の `nat-to (egress:0)` がどちらのアドレスを掴むか
# 不定になり NAT が不通になる事故が起きる (実際に発生: igc0 に静的アドレス
# とは別の DHCP リースアドレスが付き、VM から 1.1.1.1 に到達不可)。
# ベアメタルリストアのたびに手動インストール手順を踏むため毎回再発し得る。
# よってここで毎回正規化し、WAN_IF を静的アドレス 1 個だけの状態に揃える。
WAN_HOSTNAME_FILE="/etc/hostname.${WAN_IF}"
_wan_static_ip=$(awk '/^inet [0-9]/{print $2; exit}' "$WAN_HOSTNAME_FILE" 2>/dev/null || true)
if [ -n "$_wan_static_ip" ]; then
	if grep -qi '^inet6\? autoconf' "$WAN_HOSTNAME_FILE" 2>/dev/null; then
		_log "${WAN_HOSTNAME_FILE} に static(${_wan_static_ip}) + autoconf の二重定義を検出 → autoconf 行を削除..."
		grep -vi '^inet6\? autoconf' "$WAN_HOSTNAME_FILE" >"${WAN_HOSTNAME_FILE}.tmp"
		mv "${WAN_HOSTNAME_FILE}.tmp" "$WAN_HOSTNAME_FILE"
		chmod 640 "$WAN_HOSTNAME_FILE"
		_ok "${WAN_HOSTNAME_FILE} を静的アドレスのみに正規化"
	fi
	_log "${WAN_IF} の余剰 IPv4 アドレスを確認 (静的 ${_wan_static_ip} 以外を削除)..."
	ifconfig "$WAN_IF" | awk '/^[[:space:]]*inet /{print $2}' | while read -r _ip; do
		if [ "$_ip" != "$_wan_static_ip" ]; then
			_log "  余剰アドレス ${_ip} を ${WAN_IF} から削除..."
			ifconfig "$WAN_IF" inet "$_ip" delete
		fi
	done
	rcctl disable dhcpleased 2>/dev/null || true
	rcctl stop dhcpleased 2>/dev/null || true
	_ok "${WAN_IF} 正規化完了: $(ifconfig "$WAN_IF" | awk '/^[[:space:]]*inet /{printf "%s ", $2}')"
	# dhcpleased が DHCP リースで張っていた default route は rcctl stop で
	# 一緒に失われる。netstart は再実行されないため /etc/mygate が静的に
	# default route を再投入してくれることはなく、host が default route を
	# 失ったまま NAT (STEP 4) が不通になる事故が起きる
	# (実際に発生: PF/sysctl forwarding は正常なのに VM → 1.1.1.1 unreachable)。
	if ! route -n show -inet | grep -q '^default'; then
		if [ -s /etc/mygate ]; then
			_log "default route が無いことを検出 → /etc/mygate から再投入..."
			route add default "$(cat /etc/mygate)" ||
				_die "default route の再投入に失敗 (/etc/mygate: $(cat /etc/mygate))"
			_ok "default route 再投入完了: $(cat /etc/mygate)"
		else
			_die "default route が無く /etc/mygate も存在しません。手動で default gateway を設定してください"
		fi
	fi
else
	_ok "${WAN_HOSTNAME_FILE} に静的アドレス定義なし (autoconf 運用) → 正規化スキップ"
fi
