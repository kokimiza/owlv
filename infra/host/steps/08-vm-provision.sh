# shellcheck shell=ksh
# step 08 — VM 内部プロビジョニング
_step 8 "VM 内部プロビジョニング"

_vm_provision() {
	local vmname="$1" vmip="$2"
	_info "-- ${vmname} (${vmip})"
	_log "[${vmname}] プロビジョニング開始"

	# VM のホスト鍵を known_hosts に記録する (owl-control.sh で StrictHostKeyChecking=yes に使用)
	_log "[${vmname}] ホスト鍵を ssh-keyscan で取得..."
	ssh-keyscan -T 10 "$vmip" >>/etc/owlv/known_hosts 2>/dev/null
	_info "    ホスト鍵を /etc/owlv/known_hosts に記録"

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

	# install.conf が "DNS nameservers = gateway" を設定する。
	# ホスト側 unwind + pf rdr-to がゲートウェイ向け DNS クエリを 127.0.0.1:53 へ転送するため
	# resolv.conf はそのまま (= gateway IP) でよい。
	# resolvd / dhclient が resolv.conf を再上書きするのだけ防ぐ。
	_log "[${vmname}] resolvd/dhclient を停止 (resolv.conf 保護)..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"rcctl disable resolvd 2>/dev/null || true
         rcctl stop   resolvd 2>/dev/null || true
         pkill -x dhclient   2>/dev/null || true" ||
		_die "[${vmname}] DNS 保護コマンド失敗"

	# NAT + DNS 疎通確認: ここで失敗させることで pkg_add の無限リトライ (40分ハング) を防ぐ
	# ping: OpenBSD は -w (小文字) でタイムアウト指定。-W (大文字) は無効で即失敗するため使わない。
	# DNS: host/dig は base 非収録。ping でホスト名を指定すると resolv → ICMP の両方を確認できる。
	_log "[${vmname}] NAT / DNS 疎通確認..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"ping -c 2 -w 6 1.1.1.1 >/dev/null 2>&1 || { echo 'NAT 障害: 1.1.1.1 に到達不可'; exit 1; }
         ping -c 1 -w 5 cdn.openbsd.org >/dev/null 2>&1 || { echo 'DNS 障害: cdn.openbsd.org を解決できない'; exit 1; }" ||
		_die "[${vmname}] 疎通確認失敗。ホスト側で確認: pfctl -s rules / sysctl net.inet.ip.forwarding / route -n show -inet (default route の有無。dhcpleased 停止後に default route が再投入されず NAT が通らない)"

	# autoinstall が /etc/installurl をプロビジョニングサーバー (10.0.x.1/sets) に
	# 設定してしまうため、pkg_add の前に公式 CDN ミラーへ上書きする
	_log "[${vmname}] installurl を CDN ミラーへ更新..."
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"echo 'https://cdn.openbsd.org/pub/OpenBSD' > /etc/installurl"

	# setup.sh を実行。
	# vm-git だけは最後に "DEPLOY_POLL_TOKEN=<token>" を1行出力するため
	# (doc/dev_sec_ops.md §4.2)、その出力を tee /dev/stderr で複製しつつ変数に
	# 捕捉する必要がある。他の VM (特に vm-build の pkg_add / go build) は
	# パイプを挟まない素の ssh のままにする — パイプ越しだと進捗メーター
	# (\r で行を上書きする表示) が tee 側のフルバッファリングに引っかかり、
	# 長時間無音に見える事故になる (実際に発生: pkg_add が無音のまま
	# 20分以上経過したように見えたが、実際は出力が溜まっていただけだった)。
	_log "[${vmname}] setup.sh を実行中..."
	SETUP_CMD="OWL_AP_IP='${OWL_AP_IP}' OWL_DB_IP='${OWL_DB_IP}' \
         OWL_GIT_IP='${OWL_GIT_IP}' OWL_BUILD_IP='${OWL_BUILD_IP}' \
         OWL_RELEASE='${OWL_RELEASE}' GHC_VERSION='${GHC_VERSION}' \
         PG_VERSION='${PG_VERSION}' FORGEJO_VERSION='${FORGEJO_VER}' \
         FORGEJO_RUNNER_VERSION='${FORGEJO_RUNNER_VER}' \
         FORGEJO_RUNNER_SECRET='${FORGEJO_RUNNER_SECRET}' \
         OWLV_ROOT_ADMIN_USERNAME='${OWLV_ROOT_ADMIN_USERNAME}' \
         sh /provision/${vmname}/setup.sh"
	if [ "$vmname" = "vm-git" ]; then
		SETUP_OUTPUT=$(ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			"root@${vmip}" "$SETUP_CMD" 2>&1 | tee /dev/stderr)
	else
		ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
			"root@${vmip}" "$SETUP_CMD"
	fi
	_log "[${vmname}] setup.sh 完了"

	if [ "$vmname" = "vm-git" ]; then
		DEPLOY_POLL_TOKEN=$(printf '%s\n' "$SETUP_OUTPUT" | awk -F= '/^DEPLOY_POLL_TOKEN=/{print $2; exit}')
		if [ -n "$DEPLOY_POLL_TOKEN" ]; then
			install -d -m 700 /etc/owlv
			printf '%s' "$DEPLOY_POLL_TOKEN" >/etc/owlv/forgejo_token
			chmod 600 /etc/owlv/forgejo_token
			_ok "[vm-git] deploy-poll トークンを /etc/owlv/forgejo_token へ配置"
		else
			_info "[vm-git] 警告: deploy-poll トークンを取得できませんでした。setup.sh の出力を確認してください"
		fi
	fi

	# /provision/ はこの関数の先頭で作成済みなので全 VM で存在が保証されている。
	ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"date > /provision/.owl-provisioned"

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
