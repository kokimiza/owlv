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

	# リリース署名検証用の公開鍵 (signify, doc/dev_sec_ops.md §4.2) を全 VM へ
	# 配布する。公開鍵であり秘匿性は不要なため、現時点で実際に検証を行う
	# vm-audit (doc/audit_engine.md §10) 以外に置いても害はなく、将来 vm-ap側の
	# 「手動配置」(§4.2) をこの自動経路へ統一する余地も残す。秘密鍵は
	# /etc/owlv/release-signify.sec のままホストのみが保持し、ここでは公開鍵
	# (.pub) のみを転送する。
	if [ -f /etc/owlv/release-signify.pub ]; then
		scp -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
			/etc/owlv/release-signify.pub "root@${vmip}:/provision/release-signify.pub"
		_info "release-signify.pub を配布"
	else
		_info "警告: /etc/owlv/release-signify.pub が未生成 (01-host-foundation.sh 未実行?)。署名検証が必要な VM では後で再配置が必要です"
	fi

	# Audit VM 専用の読み取り専用 Forgejo トークン (doc/audit_engine.md §10)。
	# vm-git の REQUIRE_SIGNIN_VIEW=true により匿名API呼び出し・リリース資産の
	# 匿名ダウンロードは共に拒否される (実際に発生: releases 一覧取得が
	# "Only signed in user is allowed to call APIs." で 403)。write:repository
	# を持つ forgejo_token (deploy-poll 用) とは別に、read:repository のみの
	# トークンを Audit VM だけに配る (他 VM には不要な秘密を増やさない)。
	# vm-git は呼び出し順で vm-audit より先に provision されるため、この時点で
	# 既にホスト側に書き込まれている。
	if [ "$vmname" = "vm-audit" ]; then
		if [ -f /etc/owlv/audit_releases_token ]; then
			scp -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
				/etc/owlv/audit_releases_token "root@${vmip}:/provision/audit-releases-token"
			_info "audit-releases-token を配布"
		else
			_info "警告: /etc/owlv/audit_releases_token が未生成 (vm-git のプロビジョニングが先に完了している必要があります)。fohlen は匿名アクセスを試行し 403 になります"
		fi
	fi

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
         OWL_AUDIT_IP='${OWL_AUDIT_IP}' \
         OWL_RELEASE='${OWL_RELEASE}' GHC_VERSION='${GHC_VERSION}' \
         PG_VERSION='${PG_VERSION}' FORGEJO_VERSION='${FORGEJO_VER}' \
         FORGEJO_RUNNER_VERSION='${FORGEJO_RUNNER_VER}' \
         FORGEJO_RUNNER_SECRET='${FORGEJO_RUNNER_SECRET}' \
         OWLV_ROOT_ADMIN_USERNAME='${OWLV_ROOT_ADMIN_USERNAME}' \
         OWL_AUDIT_NOTIFY_WEBHOOK='${OWL_AUDIT_NOTIFY_WEBHOOK}' \
         APP_SSH_PORT='${APP_SSH_PORT}' DB_NAME='${DB_NAME}' \
         DB_APP_USER='${DB_APP_USER}' DB_REPL_USER='${DB_REPL_USER}' \
         DB_MIGRATOR_USER='${DB_MIGRATOR_USER}' \
         DB_PLATFORM_ADMIN_USER='${DB_PLATFORM_ADMIN_USER}' \
         DB_PROJECTOR_USER='${DB_PROJECTOR_USER}' \
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

		AUDIT_RELEASES_TOKEN=$(printf '%s\n' "$SETUP_OUTPUT" | awk -F= '/^AUDIT_RELEASES_TOKEN=/{print $2; exit}')
		if [ -n "$AUDIT_RELEASES_TOKEN" ]; then
			install -d -m 700 /etc/owlv
			printf '%s' "$AUDIT_RELEASES_TOKEN" >/etc/owlv/audit_releases_token
			chmod 600 /etc/owlv/audit_releases_token
			_ok "[vm-git] Audit VM 用読み取り専用トークンを /etc/owlv/audit_releases_token へ配置"
		else
			_info "[vm-git] 警告: Audit VM 用トークンを取得できませんでした。fohlen は匿名アクセスを試行し 403 になります"
		fi
	fi

	# vm-audit は setup.sh の末尾で自身の pf.conf を default-deny (SSH 受信不可)
	# に切り替えて自己ロックダウンする (鉄則①: host から audit VM への能動的な
	# 読み込み経路を持たない、infra/vm-audit/setup.sh 参照)。そのため以下の
	# 事後 SSH 呼び出しは setup.sh 自身がロックダウン前に既に行っており、
	# host 側から追って実行することはできない (実際に発生: ssh timeout)。
	if [ "$vmname" = "vm-audit" ]; then
		_log "[${vmname}] プロビジョニング完了 (完了マーカー/鍵削除は setup.sh が自己処理済み)"
		_ok "${vmname} 完了"
		return
	fi

	# vm-ap は setup.sh 内で sshd を APP_SSH_PORT (既定 8022) に切り替えるため、
	# setup.sh 実行後の事後 SSH 呼び出しはポート 22 では繋がらない (実際に発生:
	# "Connection refused" でプロビジョニング全体が失敗していた)。他 VM は
	# sshd のポートを変更しないため 22 のまま。
	local sshport=22
	[ "$vmname" = "vm-ap" ] && sshport="${APP_SSH_PORT:-8022}"

	# /provision/ はこの関数の先頭で作成済みなので全 VM で存在が保証されている。
	ssh -p "$sshport" -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" \
		"date > /provision/.owl-provisioned"

	# プロビジョニング用の使い捨て鍵を VM から削除
	_log "[${vmname}] プロビジョニング鍵を VM から削除..."
	ssh -p "$sshport" -i "$PROV_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "root@${vmip}" "
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
_vm_provision "vm-audit" "$OWL_AUDIT_IP"
_vm_provision "vm-ap" "$OWL_AP_IP"
