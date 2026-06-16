# shellcheck shell=ksh
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
match out on egress from { 10.0.1.0/24, 10.0.2.0/24 } nat-to (egress)

set block-policy drop
set skip on lo0
block all

# SSH: 管理アクセスを維持 (Yubikey セットアップ完了まで維持する §yubikey-setup.sh)
pass in on egress proto tcp to port 22 keep state

# DHCP: DISCOVER は src=0.0.0.0/dst=255.255.255.255 のブロードキャスト。
# keep state はステートエントリに有効 src が必要なため 0.0.0.0 で作れず drop される。
# quick no state で先行許可することで stateful tracking を迂回する。
pass quick on tap     proto udp from any port 68 to any port 67 no state
pass quick on vether0 proto udp from any port 67 to any port 68 no state
pass quick on vether1 proto udp from any port 67 to any port 68 no state

# VM ↔ ホスト: その他の通信
# bridge(4) のフィルタリングはブリッジ本体ではなく各メンバーで行われる。
# bridge0/1 = 手動生成スイッチ, veb0/1 = vmd 自動生成スイッチ (両方許可)
# 内部スイッチは keep state 不要。no state で通す。
pass on tap     all no state
pass on bridge0 all no state
pass on bridge1 all no state
pass on veb0    all no state
pass on veb1    all no state
pass on vether0 all no state
pass on vether1 all no state

# VM DNS → unwind (127.0.0.1:53) へリダイレクト
# install.conf の "DNS nameservers = gateway" を機能させる (step 01 で unwind 起動済み)
pass in quick on vether0 proto { udp tcp } from 10.0.1.0/24 to ${HOST_INT_IP} port 53 rdr-to 127.0.0.1
pass in quick on vether1 proto { udp tcp } from 10.0.2.0/24 to ${HOST_DEV_IP} port 53 rdr-to 127.0.0.1

# VM → インターネット: インストールセット取得 / pkg_add / ソースビルド用
pass out on egress all keep state
PFEOF
_log "pfctl -s rules:"
pfctl -s rules 2>/dev/null | while read -r l; do _log "  $l"; done
_ok "暫定 PF (NAT) 適用"
