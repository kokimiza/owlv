# step 06 — VM 内部プロビジョニング
_step 6 "VM 内部プロビジョニング"

_vm_provision() {
    local vmname="$1" vmip="$2"
    _info "-- ${vmname} (${vmip})"
    _log "[${vmname}] プロビジョニング開始"

    # VM のホスト鍵を known_hosts に記録する (owl-control.sh で StrictHostKeyChecking=yes に使用)
    _log "[${vmname}] ホスト鍵を ssh-keyscan で取得..."
    ssh-keyscan -T 10 "$vmip" >> /etc/owl/known_hosts 2>/dev/null
    _info "    ホスト鍵を /etc/owl/known_hosts に記録"

    # スクリプトと設定ファイルを VM に転送
    _log "[${vmname}] /provision ディレクトリを作成..."
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "install -d /provision"
    _log "[${vmname}] ${SELF}/${vmname}/ を VM に転送..."
    scp -i "$PROV_KEY" -o StrictHostKeyChecking=no -rq \
        "${SELF}/${vmname}/" "${SELF}/owl-config.toml" \
        "root@${vmip}:/provision/"
    _log "[${vmname}] 転送完了"

    # DR バックアップ鍵を authorized_keys に追加 (owl-control.sh 用)
    _log "[${vmname}] DR バックアップ鍵を authorized_keys に追加..."
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "install -d -m 700 /root/.ssh
         grep -qF '${BACKUP_PUBKEY}' /root/.ssh/authorized_keys 2>/dev/null || \
             echo '${BACKUP_PUBKEY}' >> /root/.ssh/authorized_keys
         chmod 600 /root/.ssh/authorized_keys"

    # setup.sh を実行
    _log "[${vmname}] setup.sh を実行中..."
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" \
        "OWL_AP_IP='${OWL_AP_IP}' OWL_DB_IP='${OWL_DB_IP}' \
         OWL_GIT_IP='${OWL_GIT_IP}' OWL_BUILD_IP='${OWL_BUILD_IP}' \
         OWL_RELEASE='${OWL_RELEASE}' GHC_VERSION='${GHC_VERSION}' \
         PG_VERSION='${PG_VERSION}' FORGEJO_VERSION='${FORGEJO_VER}' \
         sh /provision/${vmname}/setup.sh"
    _log "[${vmname}] setup.sh 完了"

    # プロビジョニング用の使い捨て鍵を VM から削除
    _log "[${vmname}] プロビジョニング鍵を VM から削除..."
    ssh -i "$PROV_KEY" -o StrictHostKeyChecking=no "root@${vmip}" "
        grep -v 'owl-prov-' /root/.ssh/authorized_keys > /root/.ssh/ak.tmp || true
        mv /root/.ssh/ak.tmp /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys
    "
    _log "[${vmname}] プロビジョニング完了"
    _ok "${vmname} 完了"
}

_vm_provision "vm-db"    "$OWL_DB_IP"
_vm_provision "vm-git"   "$OWL_GIT_IP"
_vm_provision "vm-build" "$OWL_BUILD_IP"
_vm_provision "vm-ap"    "$OWL_AP_IP"
