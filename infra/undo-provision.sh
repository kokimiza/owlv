#!/bin/sh
# undo-provision.sh — provision.sh の変更を巻き戻す緊急リセットスクリプト
#
# 【使い方】
#   doas sh /etc/owl/undo-provision.sh          # VM ディスクは残す (デフォルト)
#   doas sh /etc/owl/undo-provision.sh --wipe   # VM ディスクイメージも削除
#
# 【注意】
#   - VM の中身 (PostgreSQL データ等) は復元できない。DB バックアップを先に確保すること。
#   - --wipe を付けると /var/vmm/*.img が完全に消える。
#   - 実行後は SSH でログインできる状態を維持するよう、PF を「SSH のみ通す」ルールにする。
#
# 【このスクリプトが巻き戻すもの】
#   VM    : 強制停止 → vmd 停止・無効化
#   STEP 1: 管理スクリプト / 設定ファイル / owl-control ユーザー / login.conf
#   STEP 2: vether/bridge インターフェース / hostname.* / IP フォワーディング / PF
#   STEP 3: VM ディスクイメージ (--wipe 時のみ)
#   STEP 4: SSH 鍵 (プロビジョニング鍵・バックアップ鍵)
#   STEP 5: autoinstall サーバー残骸 (dhcpd / httpd / htdocs / 一時ファイル)
#   STEP 7: rc.conf.local / 改ざん検知ベースライン

set -eu

[ "$(id -u)" -eq 0 ] || { echo "root (doas) で実行してください" >&2; exit 1; }
[ "$(uname)" = "OpenBSD" ] || { echo "OpenBSD でのみ実行可能" >&2; exit 1; }

WIPE_DISKS=0
for arg in "$@"; do
    [ "$arg" = "--wipe" ] && WIPE_DISKS=1
done

_log()  { printf '\n[undo] %s\n' "$*"; }
_ok()   { printf '  ✓ %s\n' "$*"; }
_skip() { printf '  - %s (スキップ)\n' "$*"; }
_warn() { printf '  ⚠ %s\n' "$*" >&2; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " provision.sh 緊急巻き戻し"
if [ "$WIPE_DISKS" -eq 1 ]; then
    echo " モード: VM ディスクイメージも削除 (--wipe)"
    echo ""
    echo " 本当に /var/vmm/*.img を削除しますか？"
    echo " DB データが完全に失われます。[yes/no]"
    printf "> "
    read -r CONFIRM
    [ "$CONFIRM" = "yes" ] || { echo "中断しました"; exit 0; }
else
    echo " モード: VM ディスクイメージは残す (デフォルト)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── VM を強制停止 ────────────────────────────────────────────
_log "VM を強制停止"
for vm in vm-ap vm-db vm-git vm-build; do
    vmctl stop -f "$vm" 2>/dev/null && _ok "${vm} 停止" || _skip "${vm} (既に停止またはなし)"
done

# ── vmd 停止・クリーンアップ ─────────────────────────────────
_log "vmd を停止・無効化"
rcctl stop    vmd 2>/dev/null && _ok "vmd 停止" || _skip "vmd (既に停止)"
rcctl disable vmd 2>/dev/null || true
# rcctl で落ちきらないゾンビプロセスを SIGKILL (step 01 と同じ手順)
if pgrep -x "vmd|vmctl" >/dev/null 2>&1; then
    _warn "残存する vmd/vmctl プロセスを SIGKILL..."
    pkill -9 -x "vmd|vmctl" 2>/dev/null || true
    sleep 1
fi
rm -f /var/run/vmd.sock
_ok "vmd クリーンアップ完了"

# ── STEP 2: 仮想ネットワーク ─────────────────────────────────
_log "STEP 2: 仮想インターフェースを解除"

# bridge → vether の順で destroy (bridge が vether を参照しているため)
for iface in bridge0 bridge1 vether0 vether1; do
    ifconfig "$iface" destroy 2>/dev/null && _ok "${iface} destroy" \
        || _skip "${iface} (存在しない)"
done

# 再起動時の自動設定を無効化
for f in /etc/hostname.vether0 /etc/hostname.bridge0 \
         /etc/hostname.vether1 /etc/hostname.bridge1; do
    rm -f "$f" && _ok "削除: $f" || _skip "$f"
done

# IP フォワーディングを無効化
sysctl net.inet.ip.forwarding=0 2>/dev/null && _ok "IP フォワーディング無効" || true

# PF を「SSH のみ許可」の最小ルールにリセット
# (空にするとロックアウトされるため必ず SSH pass ルールを入れる)
WAN_IF="$(route -n show -inet | awk '/^default/{print $NF}' | head -1)"
WAN_IF="${WAN_IF:-em0}"
pfctl -f - <<PFEOF
set block-policy drop
set skip on lo0
block all
pass in on ${WAN_IF} proto tcp to port 22
pass out on ${WAN_IF} all
PFEOF
_ok "PF をリセット (SSH ポート 22 のみ通過)"

# ── STEP 5: autoinstall サーバー残骸 ─────────────────────────
_log "STEP 5: autoinstall サーバー残骸を削除"
rcctl stop    dhcpd 2>/dev/null || true
rcctl stop    httpd 2>/dev/null || true
rcctl disable dhcpd 2>/dev/null || true
rcctl disable httpd 2>/dev/null || true

# step 04 で cp -rp コピーした sets + 動的生成 install.conf
rm -rf /var/www/htdocs/sets
rm -f  /var/www/htdocs/install.conf
_ok "htdocs 残骸削除 (sets/ + install.conf)"

# step 04/05 が生成する一時ファイル群
rm -f /tmp/dhcpd-prov.conf /tmp/httpd-prov.conf
rm -f /tmp/owl-vmreload.err /tmp/owl-vs.err /tmp/owl-prod-start.err
rm -f /tmp/owl-vmctl-preinstall.* /tmp/owl-vmctl-preinstall.*.err
rm -f /tmp/owl-cons-*.log
# mkfifo で作られたコンソール FIFO (通常はスクリプトが削除するが異常終了時に残る)
find /tmp -maxdepth 1 -name 'owl-cons-in-*' -delete 2>/dev/null || true
rm -f /tmp/login.conf.new /tmp/login.conf.undo
_ok "一時ファイル削除"

# ── STEP 4: SSH 鍵 ──────────────────────────────────────────
_log "STEP 4: SSH 鍵を削除"
for key in /etc/owl/prov_ed25519 /etc/owl/prov_ed25519.pub \
           /etc/owl/backup_ed25519 /etc/owl/backup_ed25519.pub; do
    rm -f "$key" && _ok "削除: $key" || _skip "$key"
done

# ── STEP 3: VM ディスクイメージ ──────────────────────────────
_log "STEP 3: VM ディスクイメージ"
if [ "$WIPE_DISKS" -eq 1 ]; then
    for img in /var/vmm/ap.img /var/vmm/db.img /var/vmm/git.img /var/vmm/build.img; do
        rm -f "$img" && _ok "削除: $img" || _skip "$img"
    done
else
    _skip "VM ディスクイメージ (--wipe なし。手動削除: rm /var/vmm/*.img)"
fi

# ── STEP 1: 管理スクリプト / 設定ファイル ────────────────────
_log "STEP 1: 管理スクリプト・設定ファイルを削除"

for f in \
    /usr/local/sbin/owl-control.sh \
    /usr/local/sbin/owl-integrity-check.sh \
    /usr/local/sbin/owl-pfctl-pinhole \
    /etc/owl/known_hosts \
    /etc/owl/integrity-baseline.sha256 \
    /etc/owl/INTEGRITY_HOLD \
    /etc/vm.conf
do
    rm -f "$f" && _ok "削除: $f" || _skip "$f"
done

# owl-control 専用ユーザーを削除
if id owl-control >/dev/null 2>&1; then
    userdel owl-control 2>/dev/null && _ok "ユーザー owl-control 削除" || \
        _warn "owl-control ユーザーの削除に失敗。手動で: userdel owl-control"
else
    _skip "owl-control ユーザー (存在しない)"
fi

# doas.conf を最小限の wheel 許可に戻す
cat > /etc/doas.conf <<'EOF'
permit persist :wheel
EOF
_ok "/etc/doas.conf をリセット (wheel permit のみ)"

# newsyslog.conf をバックアップから復元
if [ -f /etc/newsyslog.conf.orig ]; then
    mv /etc/newsyslog.conf.orig /etc/newsyslog.conf
    _ok "/etc/newsyslog.conf を元に戻した"
else
    _warn "/etc/newsyslog.conf のバックアップなし。手動で確認してください"
fi

# crontab をリセット
cat > /etc/crontab <<'EOF'
# /etc/crontab (undo-provision.sh によりリセット)
SHELL=/bin/sh
PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
EOF
_ok "/etc/crontab をリセット"

# login.conf の daemon datasize=infinity を削除 (step 01 が追加)
if grep -q 'datasize=infinity' /etc/login.conf 2>/dev/null; then
    awk '!/datasize=infinity/' /etc/login.conf > /tmp/login.conf.undo \
        && cp /tmp/login.conf.undo /etc/login.conf \
        && rm -f /tmp/login.conf.undo \
        && cap_mkdb /etc/login.conf \
        && _ok "login.conf daemon datasize=infinity を削除"
else
    _skip "login.conf datasize=infinity (既に削除済み)"
fi

# ── STEP 7: rc.conf.local ────────────────────────────────────
_log "STEP 7: rc.conf.local をリセット"
cat > /etc/rc.conf.local <<'EOF'
# rc.conf.local (undo-provision.sh によりリセット)
pf=YES
EOF
_ok "/etc/rc.conf.local をリセット"

# ── SSH known_hosts から VM エントリを削除 ────────────────────
_log "SSH known_hosts から VM エントリを削除"
for ip in 10.0.1.10 10.0.1.20 10.0.2.10 10.0.2.20; do
    ssh-keygen -R "$ip" -f /root/.ssh/known_hosts 2>/dev/null && \
        _ok "known_hosts: ${ip} を削除" || _skip "known_hosts: ${ip} (なし)"
done

# ── ログディレクトリ ──────────────────────────────────────────
_log "ログディレクトリを削除"
rm -rf /var/log/owl && _ok "/var/log/owl 削除" || _skip "/var/log/owl"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 巻き戻し完了 ✓"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " 現在の PF: SSH (ポート 22) のみ通過"
echo " 現在の doas: wheel グループのみ permit"
echo ""
if [ "$WIPE_DISKS" -eq 0 ]; then
    echo " VM ディスクは /var/vmm/ に残っています。"
    echo " 完全に消す場合: doas sh /etc/owl/undo-provision.sh --wipe"
fi
echo " 再プロビジョニング: doas sh /etc/owl/provision.sh"
