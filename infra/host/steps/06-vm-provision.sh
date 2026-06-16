# shellcheck shell=ksh
# step 06 — VM 内部プロビジョニング
_step 6 "VM 内部プロビジョニング"

_vm_provision() {
	local vmname="$1" vmip="$2"
	_info "-- ${vmname} (${vmip})"
	_log "[${vmname}] プロビジョニング開始"

	# VM のホスト鍵を known_hosts に記録する (owl-control.sh で StrictHostKeyChecking=yes に使用)
	_log "[${vmname}] ホスト鍵を ssh-keyscan で取得..."
	ssh-keyscan -T 10 "$vmip" >>/etc/owl/known_hosts 2>/dev/null
	_info "    ホスト鍵を /etc/owl/known_hosts に記録"

	# スクリプトと設定ファイルを VM に転送
	_log "[${vmname}] /provision ディレクトリを作成..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"install -d /provision"
	_log "[${vmname}] ${SELF}/${vmname}/ を VM に転送..."
	scp -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -rq \
		"${SELF}/${vmname}/" "${SELF}/owl-config.toml" \
		"root@${vmip}:/provision/"
	_log "[${vmname}] 転送完了"

	# DR バックアップ鍵を authorized_keys に追加 (owl-control.sh 用)
	_log "[${vmname}] DR バックアップ鍵を authorized_keys に追加..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"install -d -m 700 /root/.ssh
         grep -qF '${BACKUP_PUBKEY}' /root/.ssh/authorized_keys 2>/dev/null || \
             echo '${BACKUP_PUBKEY}' >> /root/.ssh/authorized_keys
         chmod 600 /root/.ssh/authorized_keys"

	# install.conf で DNS nameservers = gateway (ホスト) と設定されるが、ホストに
	# DNS フォワーダーは存在しないため名前解決できない。
	# resolvd / dhclient が resolv.conf を上書きし直すのを防ぐため両方停止してから固定する。
	_log "[${vmname}] DNS を固定 (1.1.1.1)..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"rcctl disable resolvd 2>/dev/null || true
         rcctl stop   resolvd 2>/dev/null || true
         pkill -x dhclient   2>/dev/null || true
         echo 'nameserver 1.1.1.1' > /etc/resolv.conf" ||
		_die "[${vmname}] DNS 固定コマンド失敗"

	# NAT + DNS 疎通確認: ここで失敗させることで pkg_add の無限リトライ (40分ハング) を防ぐ
	_log "[${vmname}] NAT / DNS 疎通確認..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 || { echo 'NAT 障害: 1.1.1.1 に到達不可'; exit 1; }
         host cdn.openbsd.org 1.1.1.1 >/dev/null 2>&1 || { echo 'DNS 障害: cdn.openbsd.org を解決できない'; exit 1; }" ||
		_die "[${vmname}] 疎通確認失敗。ホスト側で確認: pfctl -s nat / sysctl net.inet.ip.forwarding"

	# autoinstall が /etc/installurl をプロビジョニングサーバー (10.0.x.1/sets) に
	# 設定してしまうため、pkg_add の前に公式 CDN ミラーへ上書きする
	_log "[${vmname}] installurl を CDN ミラーへ更新..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"echo 'https://cdn.openbsd.org/pub/OpenBSD' > /etc/installurl"

	# setup.sh を実行
	_log "[${vmname}] setup.sh を実行中..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"OWL_AP_IP='${OWL_AP_IP}' OWL_DB_IP='${OWL_DB_IP}' \
         OWL_GIT_IP='${OWL_GIT_IP}' OWL_BUILD_IP='${OWL_BUILD_IP}' \
         OWL_RELEASE='${OWL_RELEASE}' GHC_VERSION='${GHC_VERSION}' \
         PG_VERSION='${PG_VERSION}' FORGEJO_VERSION='${FORGEJO_VER}' \
         FORGEJO_RUNNER_VERSION='${FORGEJO_RUNNER_VER}' \
         FORGEJO_RUNNER_SECRET='${FORGEJO_RUNNER_SECRET}' \
         sh /provision/${vmname}/setup.sh"
	_log "[${vmname}] setup.sh 完了"

	# プロビジョニング用の使い捨て鍵を VM から削除
	_log "[${vmname}] プロビジョニング鍵を VM から削除..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" "
        grep -v 'owl-prov-' /root/.ssh/authorized_keys > /root/.ssh/ak.tmp || true
        mv /root/.ssh/ak.tmp /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    "
	_log "[${vmname}] プロビジョニング完了"
	_ok "${vmname} 完了"
}

_vm_provision "vm-db" "$OWL_DB_IP"
_vm_provision "vm-git" "$OWL_GIT_IP"
_vm_provision "vm-build" "$OWL_BUILD_IP"
_vm_provision "vm-ap" "$OWL_AP_IP"
