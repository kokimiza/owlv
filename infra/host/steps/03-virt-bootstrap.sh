# shellcheck shell=ksh
# step 03 — 仮想化基盤 (vmd) 起動
_step 3 "仮想化基盤 (vmd) 起動"

# ── bridge 設定 ──────────────────────────────────────────────
# 【超堅牢化】再実行時や前回クラッシュ時のゾンビプロセス、カーネルロックを完全に破砕する
_log "vmd の完全停止とクリーンアップを開始..."
rcctl stop vmd 2>/dev/null || true
sleep 1

# rcctl で落ちきらないゾンビプロセス（vmd/vmctl）を強制シグナルで確実に仕留める
if pgrep -x "vmd|vmctl" >/dev/null 2>&1; then
	_log "警告: 残存する vmd/vmctl プロセスを検出。SIGKILL を送出します..."
	pkill -9 -x "vmd|vmctl" || true
	sleep 2
fi

# VMM カーネルドライバのリセット（これを行うことで vcpu_assert_irq のロックが解放される）
if [ -c /dev/vmm ]; then
	_log "VMM カーネルデバイスの状態を強制リセット中..."
	# 一度 vmd のソケットファイルを確実に削除してデッドロックを防ぐ
	rm -f /var/run/vmd.sock
fi
_log "vmd の完全クリーンアップ完了"

# ── internal_lan: vether0 (IP) + bridge0 (スイッチ) ──────
_log "vether0 を destroy → create..."
ifconfig vether0 destroy 2>/dev/null && _log "vether0 destroy 完了" || _log "vether0 は存在しなかった"
ifconfig vether0 create
_log "vether0 に inet ${HOST_INT_IP} netmask 255.255.255.0 up を設定..."
ifconfig vether0 inet "${HOST_INT_IP}" netmask 255.255.255.0 up ||
	_die "vether0 への IP 設定失敗"
_log "vether0 状態: $(ifconfig vether0 | grep 'inet ')"

_log "bridge0 を destroy → create → vether0 を追加..."
ifconfig bridge0 destroy 2>/dev/null && _log "bridge0 destroy 完了" || _log "bridge0 は存在しなかった"
ifconfig bridge0 create
ifconfig bridge0 add vether0
ifconfig bridge0 up
_log "bridge0 members: $(_bridge_members bridge0)"

# ── dev_lan: vether1 (IP) + bridge1 (スイッチ) ──────────
_log "vether1 を destroy → create..."
ifconfig vether1 destroy 2>/dev/null && _log "vether1 destroy 完了" || _log "vether1 は存在しなかった"
ifconfig vether1 create
_log "vether1 に inet ${HOST_DEV_IP} netmask 255.255.255.0 up を設定..."
ifconfig vether1 inet "${HOST_DEV_IP}" netmask 255.255.255.0 up ||
	_die "vether1 への IP 設定失敗"
_log "vether1 状態: $(ifconfig vether1 | grep 'inet ')"

_log "bridge1 を destroy → create → vether1 を追加..."
ifconfig bridge1 destroy 2>/dev/null && _log "bridge1 destroy 完了" || _log "bridge1 は存在しなかった"
ifconfig bridge1 create
ifconfig bridge1 add vether1
ifconfig bridge1 up
_log "bridge1 members: $(_bridge_members bridge1)"

# 再起動時も自動設定されるよう hostname.* を書いておく (パーミッション 640 必須)
_log "hostname.vether0/bridge0/vether1/bridge1 を書き込み..."
printf 'inet %s 255.255.255.0\nup\n' "${HOST_INT_IP}" >/etc/hostname.vether0
chmod 640 /etc/hostname.vether0
printf 'add vether0\nup\n' >/etc/hostname.bridge0
chmod 640 /etc/hostname.bridge0
printf 'inet %s 255.255.255.0\nup\n' "${HOST_DEV_IP}" >/etc/hostname.vether1
chmod 640 /etc/hostname.vether1
printf 'add vether1\nup\n' >/etc/hostname.bridge1
chmod 640 /etc/hostname.bridge1

_ok "vether0+bridge0 (${HOST_INT_IP}) / vether1+bridge1 (${HOST_DEV_IP}) 設定"

# vmd をスイッチのみの最小 config で起動する
# ディスクイメージ参照を含む完全な vm.conf は STEP 7 (VM OS autoinstall) で配置する
_log "最小 vm.conf (スイッチ定義のみ) を書き込み..."
cat >/etc/vm.conf <<'VMDEOF'
switch "internal_lan" {
    interface bridge0
}
switch "dev_lan" {
    interface bridge1
}
VMDEOF

# OpenBSD では anonymous mmap が datasize rlimit にカウントされる。
# vmd は daemon クラスで動作するため、daemon クラスの datasize が VM の最大メモリ
# (vm-build: 4G) を下回ると vmctl start が ENOMEM で失敗する。
# 先に確認・修正してから vmd を起動することで確実にリミットを反映させる。
_log "login.conf daemon クラスの datasize を確認..."
_daemon_ds=$(awk '
    /^daemon:/{in_d=1; next}
    in_d && /^[^: \t]/{exit}
    in_d && /datasize[^-]/{print; exit}
' /etc/login.conf)
_log "  現在値: ${_daemon_ds:-(エントリなし)}"
if ! printf '%s' "${_daemon_ds}" | grep -qi 'infinity'; then
	_log "  daemon datasize が infinity でない → /etc/login.conf を修正します..."
	awk '
        /^daemon:/{in_d=1; print; next}
        in_d && /^[^: \t]/{
            if (!added) { print "\t:datasize=infinity:\\"; added=1 }
            in_d=0
        }
        in_d && /datasize[^-]/{
            sub(/datasize[^:]*/, "datasize=infinity")
            added=1
        }
        { print }
        END { if (in_d && !added) print "\t:datasize=infinity:\\" }
    ' /etc/login.conf >/tmp/login.conf.new &&
		cp /tmp/login.conf.new /etc/login.conf ||
		_die "login.conf の更新に失敗しました"
	cap_mkdb /etc/login.conf
	_ok "login.conf daemon datasize=infinity 設定 (cap_mkdb 完了)"
else
	_ok "login.conf daemon datasize=infinity ✓"
fi

_log "vmd を enable + start..."
rcctl enable vmd
if ! rcctl start vmd 2>/dev/null; then
	_log "vmd 起動失敗 — /var/log/messages の直近ログ:"
	grep -i vmd /var/log/messages | tail -10 | while read -r l; do _log "  $l"; done
	_die "vmd の起動に失敗しました"
fi
sleep 1
_vmd_pids=$(pgrep -x vmd | tr '\n' ' ')
_log "vmd PID: ${_vmd_pids:-不明}"
_log "vmctl status:"
if ! _log_vmctl_status ""; then
	_log "vmd 起動直後の vmctl status 取得に失敗 — /var/log/messages の直近ログ:"
	grep -Ei 'vmd|vmm' /var/log/messages | tail -15 | while read -r l; do _log "  $l"; done
	_die "vmd は起動しましたが vmctl status に応答しません"
fi
_ok "vmd 起動 (スイッチのみ)"

# ── unwind (ホスト内蔵 DNS リゾルバー) ──────────────────────
# VM の install.conf は "DNS nameservers = gateway" を指定するが、
# ゲートウェイ (ホスト) に DNS フォワーダーがないと pkg_add が無限リトライになる。
# unwind は base 同梱 (pkg_add 不要)。pf の rdr-to で VM の DNS クエリを
# 127.0.0.1:53 へ転送することで gateway = DNS サーバーを実現する (STEP 4 参照)。
_log "unwind (DNS リゾルバー) を設定・起動..."
# unwind.conf: forwarder の区切りはスペース (コンマ不可)
cat >/etc/unwind.conf <<'UNWINDEOF'
forwarder { 1.1.1.1 1.0.0.1 }
UNWINDEOF
rcctl enable unwind
if ! rcctl start unwind; then
	_log "unwind 起動失敗 — /var/log/daemon 直近ログ:"
	grep -i unwind /var/log/daemon 2>/dev/null | tail -5 | while read -r l; do _log "  $l"; done
	_die "unwind の起動に失敗しました"
fi
_ok "unwind 起動 (127.0.0.1:53 → 1.1.1.1)"
