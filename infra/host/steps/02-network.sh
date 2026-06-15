# step 02 — 仮想ネットワーク設定
_step 2 "仮想ネットワーク設定"

# VM がミラーからインストールセットを取得できるよう IP フォワーディング + NAT を有効化
# (本番封鎖は STEP 7 で適用するため、ここでは最小限のルールのみ)
_log "IP フォワーディングを有効化..."
sysctl net.inet.ip.forwarding=1
_log "暫定 PF ルールを適用 (NAT: VM → WAN)..."
# 注意: `cat | pfctl -f - <<PFEOF` は NG。
#   ヒアドキュメントは右辺 (pfctl) に渡るが left の cat は端末 stdin を待ちフリーズする。
#   正しくは pfctl に直接ヒアドキュメントを渡す。
pfctl -f - <<PFEOF
# プロビジョニング中の暫定 PF ルール
# NAT: VM → インターネット (OpenBSD ミラーからインストールセットを取得)
match out on ${WAN_IF} from { 10.0.1.0/24, 10.0.2.0/24 } nat-to (${WAN_IF})

set block-policy drop
set skip on lo0
block all

# keep state を明示する。
# flags S/SA のみでは stateful tracking が確立されず、戻りパケットが落ちる。

# SSH: 管理アクセスを維持 (Yubikey セットアップ完了まで維持する §yubikey-setup.sh)
pass in on ${WAN_IF} proto tcp to port 22 keep state

# VM ↔ ホスト: DHCP / HTTP (autoinstall) + SSH (プロビジョニング)
# bridge0/1 = 手動生成スイッチ, veb0/1 = vmd 自動生成スイッチ (両方許可)
# vether0/1 = ホスト IP (VM-ホスト通信)
pass on bridge0 all keep state
pass on bridge1 all keep state
pass on veb0    all keep state
pass on veb1    all keep state
pass on vether0 all keep state
pass on vether1 all keep state

# VM → インターネット: インストールセット取得のみ
pass out on ${WAN_IF} all keep state
PFEOF
_log "pfctl -s rules:"
pfctl -s rules 2>/dev/null | while read -r l; do _log "  $l"; done
_ok "暫定 PF (NAT) 適用"
