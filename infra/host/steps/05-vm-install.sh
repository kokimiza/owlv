# step 05 — VM OS autoinstall
_step 5 "VM OS autoinstall"
_log "ホストメモリ:"
_log "  物理:   $(sysctl -n hw.physmem | awk '{printf "%d MB", $1/1024/1024}')"
_log "  実空き: $(vmstat 2>/dev/null | awk 'END{print $4}' || echo '不明')"
_log "VMM 状態:"
dmesg | grep -Ei 'vmm|vmx|svm|ept|rvi' | while read -r l; do _log "  dmesg: $l"; done
_log_vmctl_status "vmctl: " || _log "  vmctl: (取得失敗)"
# vmm(4) が利用可能か確認する (VT-x/AMD-V が BIOS で無効だと vmm0 がアタッチされない)
if ! dmesg | grep -q 'vmm0 at mainbus0'; then
	_die "vmm(4) ドライバーが見つかりません。\n  原因: CPU が仮想化非対応、または BIOS で Intel VT-x / AMD-V が無効です。\n  対処: BIOS/UEFI で VT-x (Intel) または SVM (AMD) を有効にして再起動してください。"
fi
_info "install.conf を自動生成し、1 台ずつ順番にインストールします。"
_info "インストールセットは ${SELF}/sets/ から取得します。"
_info "インストーラー起動メモリ: 512M (-m オプション; vm.conf の本番値とは別)"

_vm_install() {
	local vmname="$1" vmip="$2" gateway="$3" disk="$4" swname="$5" setnames="${6:--x* -game* -man* done}"

	_info "-- ${vmname} (${vmip})"
	_log "[${vmname}] install.conf を生成 (gateway=${gateway})..."

	# install.conf を動的生成して httpd のルートに置く
	# VM の installer が http://<gateway>/install.conf を取得する
	cat >/var/www/htdocs/install.conf <<EOF
System hostname = ${vmname}
Password for root = *
Network interfaces = vio0
IPv4 address for vio0 = ${vmip}
Netmask for vio0 = 255.255.255.0
Default IPv4 route = ${gateway}
DNS domain name = local
DNS nameservers = ${gateway}
Do you expect to run the X Window System = no
Do you want the X Window System to be started by xdm = no
Setup a user = no
Allow root ssh login = prohibit-password
Public ssh key for root account = ${PROV_PUBKEY}
What timezone are you in = Asia/Tokyo
Which disk is the root disk = sd0
Use (W)hole disk MBR, whole disk (G)PT or (E)dit? = gpt
Set name(s) = ${setnames}
Location of sets = http
HTTP Server = ${gateway}
Server directory = /sets
Fetching of BUILDINFO failed. Continue anyway? = yes
Download firmware? = no
EOF

	# bsd.rd はダウンロードせず infra/sets/ に置かれたものを使う (なければ即エラー)
	local bsdrd="${SELF}/sets/bsd.rd"
	local inst_mem="512M"
	[ -f "$bsdrd" ] || _die "bsd.rd が見つかりません: ${bsdrd}"
	_log "[${vmname}] bsd.rd: $(ls -l "$bsdrd")"
	_log "[${vmname}] disk:   $(ls -l "$disk")"

	# running/starting の場合のみ停止する。
	# vmd を最小 vm.conf で再起動しているため VM エントリはないはず。
	# 再実行時に running/starting のまま残っている場合のガード。
	_log "[${vmname}] 既存 VM 状態を確認..."
	_vmstate=$(_vm_state_for "$vmname" || true)
	_log "[${vmname}] 現在状態: ${_vmstate:-なし}"
	if [ "$_vmstate" = "running" ] || [ "$_vmstate" = "starting" ]; then
		_log "[${vmname}] 実行中 → vmctl stop -f (3 秒待機)..."
		vmctl stop -f "$vmname" 2>/dev/null || true
		sleep 3
		_log "[${vmname}] 停止後の状態: $(_vm_state_for "$vmname" || true)"
	fi

	_log "実空きメモリ: $(vmstat 2>/dev/null | awk 'END{print $4}' || echo '不明')"

	# vmm-bios 読み取り可能か確認 (欠落または権限不足だと "failed to receive boot fd" で失敗)
	[ -r /etc/firmware/vmm-bios ] || _die "vmm-bios が読み取れません — 'fw_update vmm' を実行してください"

	# vmd が確実に応答できる状態か確認 (VM 間での vmd クラッシュ対策)
	_vmd_chk=0
	while ! _vmctl_status_ok; do
		sleep 1
		_vmd_chk=$((_vmd_chk + 1))
		[ "$_vmd_chk" -lt 10 ] || _die "[${vmname}] vmctl start 前に vmd が応答しません"
	done

	# インストーラー用 VM 定義を /etc/vm.conf に書いてから起動する。
	# vmctl start -b は vmctl→vmd の fd 受け渡しに依存し、環境によって
	# "failed to receive boot fd" になるため、vmd が boot/disk を直接開く形にする。
	_log "[${vmname}] インストーラー用 vm.conf を書き込み..."
	cat >/etc/vm.conf <<VMDEOF
switch "internal_lan" {
    interface bridge0
}
switch "dev_lan" {
    interface bridge1
}
vm "${vmname}" {
    disable
    memory ${inst_mem}
    boot "${bsdrd}"
    boot device net
    disk "${disk}" format raw
    interface { switch "${swname}" }
}
VMDEOF
	chmod 600 /etc/vm.conf
	if ! vmctl reload 2>/tmp/owl-vmreload.err; then
		_log "[${vmname}] vmctl reload 失敗:"
		while read -r l; do _log "  $l"; done </tmp/owl-vmreload.err
		rm -f /tmp/owl-vmreload.err
		_die "[${vmname}] インストーラー用 vm.conf の reload に失敗"
	fi
	rm -f /tmp/owl-vmreload.err

	_log "[${vmname}] vmctl -v start ${vmname}"
	# vmctl stop -f 後に VMM カーネルスロットの解放が遅れる場合 EALREADY になる。
	# vmd が vm.conf で管理する VM は stopped のまま残るため、解放完了まで
	# リトライで対処する (最大 40 秒 = 20 × 2秒)。
	_vs_n=0
	until vmctl -v start "$vmname" 2>/tmp/owl-vs.err; do
		if grep -q 'already in progress' /tmp/owl-vs.err 2>/dev/null; then
			_vs_n=$((_vs_n + 1))
			if [ "$_vs_n" -ge 20 ]; then
				_log "VMM スロット解放タイムアウト — /var/log/messages:"
				grep -Ei 'vmd|vmm|firmware' /var/log/messages | tail -20 |
					while read -r l; do _log "  $l"; done
				rm -f /tmp/owl-vs.err
				_die "[${vmname}] vmctl start 失敗 (EALREADY 20回)"
			fi
			_log "[${vmname}] VMM スロット解放待機 ${_vs_n}/20 (2秒)..."
			sleep 2
		else
			_log "vmctl start stderr:"
			while read -r l; do _log "  $l"; done </tmp/owl-vs.err
			_log "vmctl start 失敗 — /var/log/messages:"
			grep -Ei 'vmd|vmm|firmware' /var/log/messages | tail -20 | while read -r l; do _log "  $l"; done
			_log "daemon クラス datasize:"
			awk '/^daemon:/,/^[^: \t]/' /etc/login.conf | grep 'datasize' |
				while read -r l; do _log "  $l"; done
			rm -f /tmp/owl-vs.err
			_die "[${vmname}] vmctl start 失敗"
		fi
	done
	rm -f /tmp/owl-vs.err
	_info "    インストール中 (数分かかります)..."
	_log "[${vmname}] SSH 待機開始 (最大 10 分)..."
	# コンソールは 1 回だけ接続してログに流す。
	# 定期的に connect/SIGTERM を繰り返すと cu がマスター pty を閉じるたびに
	# VM の com0 が HUP → vmd がクラッシュしてホストが落ちる。
	# FIFO の write 端 (fd 9) を保持することで cu に EOF を送らず接続を維持する。
	local _cons_fifo="/tmp/owl-cons-in-${vmname}-$$"
	local _cons_log="/tmp/owl-cons-${vmname}-$$.log"
	mkfifo -m 600 "$_cons_fifo"
	vmctl console "$vmname" <"$_cons_fifo" 2>/dev/null |
		awk '{ gsub(/\r/,""); gsub(/\033\[[0-9;]*[A-Za-z]/,""); print; fflush() }' \
			>>"$_cons_log" &
	local _cons_bg=$!
	exec 9>"$_cons_fifo" # write 端を保持 → cu が EOF を受け取らない

	# bsd.rd インストーラーは sshd を持たないため SSH 待機では完了を検出できない。
	# 成功すると "CONGRATULATIONS" が出た後に vmmci0: powerdown → vmd が bsd.rd で
	# 再起動するリブートループに入るため、CONGRATULATIONS を検出次第強制停止する。
	_inst_n=0
	while [ "$_inst_n" -lt 120 ]; do
		if grep -q 'CONGRATULATIONS' "$_cons_log" 2>/dev/null; then
			_log "[${vmname}] インストール成功を確認 (CONGRATULATIONS)"
			break
		fi
		_inst_n=$((_inst_n + 1))
		if [ $((_inst_n % 4)) -eq 0 ]; then
			_log "  インストール待機中 ... $(((_inst_n * 5) / 60)) 分経過"
			_ctail=$(tail -3 "$_cons_log" 2>/dev/null) || true
			[ -n "$_ctail" ] && printf '%s\n' "$_ctail" |
				while read -r l; do _log "  [${vmname}] ${l}"; done
		fi
		sleep 5
	done

	exec 9>&-
	wait "$_cons_bg" 2>/dev/null || true

	if ! grep -q 'CONGRATULATIONS' "$_cons_log" 2>/dev/null; then
		_log "[${vmname}] インストールログ (末尾 20 行):"
		tail -20 "$_cons_log" 2>/dev/null | while read -r l; do _log "  $l"; done
		rm -f "$_cons_fifo" "$_cons_log"
		_die "[${vmname}] インストールタイムアウト (CONGRATULATIONS を検出できず)"
	fi
	rm -f "$_cons_fifo" "$_cons_log"

	_log "[${vmname}] VM を強制停止 (bsd.rd リブートループを断ち切る)..."
	vmctl stop -f "$vmname" 2>/dev/null || true
	_stop_n=0
	while :; do
		_stop_state=$(_vm_state_for "$vmname" || true)
		case "$_stop_state" in
		running | stopping | starting) ;;
		*) break ;;
		esac
		sleep 2
		_stop_n=$((_stop_n + 1))
		[ "$_stop_n" -lt 15 ] || break
	done
	_log "[${vmname}] 停止後状態: $(_vm_state_for "$vmname" || echo 'なし')"
	_ok "${vmname} インストール完了"
}

_wait_ssh() {
	local ip="$1" vmname="$2" cons_log="${3:-}"
	local n=0
	while [ "$n" -lt 120 ]; do
		if ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=4 \
			-o BatchMode=yes "root@${ip}" true 2>/dev/null; then
			return 0
		fi
		n=$((n + 1))
		if [ $((n % 4)) -eq 0 ]; then
			_log "  SSH 待機中 ${ip} ... $((n * 5)) 秒経過 / 600 秒"
			if [ -n "$cons_log" ]; then
				_cons=$(tail -5 "$cons_log" 2>/dev/null) || true
				if [ -n "$_cons" ]; then
					printf '%s\n' "$_cons" |
						while read -r l; do _log "  [${vmname}] ${l}"; done
				else
					_log "  [${vmname}]"
				fi
			fi
		fi
		sleep 5
	done
	_log "SSH タイムアウト — vmctl status:"
	vmctl status 2>/dev/null | while read -r l; do _log "  $l"; done
	_die "${ip} への SSH がタイムアウト (10 分)"
}

# 再実行時に前回の VM が残っていた場合だけ停止する。
# この後は VM ごとにインストーラー用 vm.conf を reload し、1 台ずつ起動する。
_log "実行中 VM をインストール前に停止..."

# ① 実行中 VM を先に停止する
_status_tmp="/tmp/owl-vmctl-preinstall.$$"
if ! _vmctl_status_to "$_status_tmp"; then
	_log "vmd が応答しません — /var/log/messages (直近 vmd/vmm ログ):"
	grep -Ei 'vmd|vmm' /var/log/messages | tail -15 | while read -r l; do _log "  $l"; done
	rm -f "$_status_tmp" "${_status_tmp}.err"
	_die "インストール開始前に vmd が応答しません"
fi
_running_vms=$(awk 'NR>1 && ($(NF-1)=="running"||$(NF-1)=="starting"){print $NF}' "$_status_tmp" | tr '\n' ' ')
if [ -n "${_running_vms}" ]; then
	_log "実行中 VM を停止: ${_running_vms}"
	for _vm in ${_running_vms}; do
		vmctl stop -f "${_vm}" 2>/dev/null || true
	done
	# running/starting がなくなるまで待つ (stopped は vm.conf 定義 VM が永続するため無視)
	_sw=0
	while vmctl status 2>/dev/null |
		awk 'NR>1 && ($(NF-1)=="running"||$(NF-1)=="starting"){f=1} END{exit !f}'; do
		sleep 1
		_sw=$((_sw + 1))
		[ "$_sw" -lt 30 ] || {
			_log "警告: 30秒後も running VM が残存 — 続行"
			break
		}
	done
	_log "全 VM stopped 状態到達 (${_sw}秒待機)"
fi
rm -f "$_status_tmp" "${_status_tmp}.err"

# vmd が応答できる状態か確認する
if ! _vmctl_status_ok; then
	_log "vmd が応答しません — /var/log/messages (直近 vmd/vmm ログ):"
	grep -Ei 'vmd|vmm' /var/log/messages | tail -15 | while read -r l; do _log "  $l"; done
	_die "インストール開始前に vmd が応答しません"
fi
_status_tmp="/tmp/owl-vmctl-preinstall.$$"
if _vmctl_status_to "$_status_tmp"; then
	_log "インストール前 VM 状態: $(awk 'NR>1{print $NF"("$(NF-1)")"}' "$_status_tmp" | tr '\n' ' ')"
else
	_log "インストール前 VM 状態: (取得失敗)"
fi
rm -f "$_status_tmp" "${_status_tmp}.err"

_vm_install "vm-db" "$OWL_DB_IP" "$HOST_INT_IP" "/var/vmm/db.img" "internal_lan"
_vm_install "vm-git" "$OWL_GIT_IP" "$HOST_DEV_IP" "/var/vmm/git.img" "dev_lan"
_vm_install "vm-build" "$OWL_BUILD_IP" "$HOST_DEV_IP" "/var/vmm/build.img" "dev_lan"
_vm_install "vm-ap" "$OWL_AP_IP" "$HOST_INT_IP" "/var/vmm/ap.img" "internal_lan" "-comp* -x* -game* -man* done"

# 全台の OS クリーンインストールが成功した後に、完全な vm.conf を適用
_log "全 VM の OS インストール完了。本番用 vm.conf を配置して reload します..."
install -m 600 "${SELF}/host/conf/vmd.conf" /etc/vm.conf
if vmctl reload 2>/dev/null; then
	_log "vmctl reload 成功（本番定義へ移行）"
else
	_log "vmctl reload 失敗 → rcctl restart vmd にフォールバック"
	rcctl restart vmd
fi
_ok "本番用 vm.conf 適用完了"

_log "本番 VM を起動して SSH 応答を確認..."
for _vm in vm-db vm-git vm-build vm-ap; do
	_state=$(_vm_state_for "$_vm" || true)
	if [ "$_state" != "running" ] && [ "$_state" != "starting" ]; then
		_log "[${_vm}] vmctl start"
		vmctl start "$_vm" 2>/tmp/owl-prod-start.err || {
			while read -r l; do _log "  $l"; done </tmp/owl-prod-start.err
			rm -f /tmp/owl-prod-start.err
			_die "[${_vm}] 本番 VM 起動に失敗"
		}
		rm -f /tmp/owl-prod-start.err
	else
		_log "[${_vm}] 既に ${_state}"
	fi
done
_log "本番 VM 状態:"
_log_vmctl_status "" || _log "  (取得失敗)"
_wait_ssh "$OWL_DB_IP" "vm-db"
_wait_ssh "$OWL_GIT_IP" "vm-git"
_wait_ssh "$OWL_BUILD_IP" "vm-build"
_wait_ssh "$OWL_AP_IP" "vm-ap"
_ok "本番 VM 起動確認完了"
