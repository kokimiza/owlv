# shellcheck shell=ksh
# step 06 — SSH 鍵生成 + autoinstall サーバー起動
_step 6 "SSH 鍵生成"

# プロビジョニング用の使い捨て鍵 (STEP 9 で削除)。
# 再実行時に前回分が残っていると ssh-keygen が対話的に上書き確認を出して
# 止まるため、生成前に必ず削除する (毎回作り直す前提の鍵なので安全)。
_log "プロビジョニング鍵を生成: ${PROV_KEY}"
rm -f "$PROV_KEY" "${PROV_KEY}.pub"
ssh-keygen -t ed25519 -N "" -C "owl-prov-$(date +%Y%m%d)" -f "$PROV_KEY" -q
chmod 600 "$PROV_KEY"
PROV_PUBKEY="$(cat ${PROV_KEY}.pub)"
_log "プロビジョニング公開鍵: ${PROV_PUBKEY}"
_ok "プロビジョニング鍵: ${PROV_KEY}"

# owl-control.sh が VM に SSH するために使用
_log "DR バックアップ鍵を生成: ${BACKUP_KEY}"
rm -f "$BACKUP_KEY" "${BACKUP_KEY}.pub"
ssh-keygen -t ed25519 -N "" -C "owl-backup-$(date +%Y%m%d)" -f "$BACKUP_KEY" -q
chmod 600 "$BACKUP_KEY"
_ok "DR バックアップ鍵: ${BACKUP_KEY} (各 VM の authorized_keys に追加される)"
BACKUP_PUBKEY="$(cat ${BACKUP_KEY}.pub)"
_log "バックアップ公開鍵: ${BACKUP_PUBKEY}"

# autoinstall サーバー (dhcpd + httpd)
cat >/tmp/dhcpd-prov.conf <<DHCP
option domain-name-servers ${HOST_INT_IP};
subnet 10.0.1.0 netmask 255.255.255.0 {
    range 10.0.1.200 10.0.1.210;
    option routers ${HOST_INT_IP};
    next-server ${HOST_INT_IP};
    filename "auto_install";
}
subnet 10.0.2.0 netmask 255.255.255.0 {
    range 10.0.2.200 10.0.2.210;
    option routers ${HOST_DEV_IP};
    next-server ${HOST_DEV_IP};
    filename "auto_install";
}
DHCP
# dhcpd は IP を持つ vether 上で listen する (bridge は L2 スイッチのみで IP なし)
# rcctl restart は "enabled" なサービスにしか使えない。
# STEP 9 で disable されている再実行時のために enable → stop(安全) → start の順にする。
_log "dhcpd を enable → flags 設定 → 起動..."
rcctl enable dhcpd
rcctl set dhcpd flags "-c /tmp/dhcpd-prov.conf vether0 vether1"
rcctl stop dhcpd 2>/dev/null || true # 再実行時の既存インスタンスを停止

# レンジは 10.0.1.200-210 / 10.0.2.200-210 (各 11 個) しかない。
# vmd は vio0 に毎回ランダム MAC を割り振るため、ベアメタルリストアの
# 再実行を繰り返すと /var/db/dhcpd.leases に古い MAC のリースが積み上がり、
# プール枯渇で "no free leases" になり VM の autoinstall が失敗する事故が起きる
# (実際に発生: vm-db の vio0 が DHCP アドレスを取得できず autoinstall が進行不能)。
# 各プロビジョニングは常に新規インストールなので古いリースは不要 → 毎回破棄する。
_log "dhcpd.leases をリセット (古いリースによるプール枯渇を防止)..."
: >/var/db/dhcpd.leases

rcctl start dhcpd
_log "dhcpd PID: $(pgrep -x dhcpd || echo '不明')"

# httpd は /var/www に chroot するため root は chroot 内のパスで指定する
install -d /var/www/htdocs
# OpenBSD に nullfs がないため sets をコピーする (07-lockdown.sh で rm -rf)
[ -d "${SELF}/sets" ] || _die "インストールセットが見つかりません: ${SELF}/sets\n  事前に scp -r infra/sets <host>:/etc/owlv/infra/ してください"
[ -f "${SELF}/sets/bsd.rd" ] || _die "bsd.rd が見つかりません: ${SELF}/sets/bsd.rd"
[ -f "${SELF}/sets/BUILDINFO" ] || _die "BUILDINFO が見つかりません: ${SELF}/sets/BUILDINFO\n  取得方法: ftp https://cdn.openbsd.org/pub/OpenBSD/7.9/amd64/BUILDINFO"
install -d /var/www/htdocs/sets
cp -rp "${SELF}/sets/." /var/www/htdocs/sets/
cat >/tmp/httpd-prov.conf <<HTTP
server "prov" {
    listen on ${HOST_INT_IP} port 80
    listen on ${HOST_DEV_IP} port 80
    root "/htdocs"
    directory auto index
}
HTTP
_log "httpd を enable → flags 設定 → 起動..."
rcctl enable httpd
rcctl set httpd flags "-f /tmp/httpd-prov.conf"
rcctl stop httpd 2>/dev/null || true # 再実行時の既存インスタンスを停止
rcctl start httpd
_log "httpd PID: $(pgrep -x httpd || echo '不明')"
_ok "DHCP / HTTP サーバー起動"
