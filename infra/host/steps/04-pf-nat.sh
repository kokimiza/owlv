# shellcheck shell=ksh
# step 04 — 暫定 PF (NAT) 設定
_step 4 "暫定 PF (NAT) 設定"

# VM がミラーからインストールセットを取得できるよう IP フォワーディング + NAT を有効化
# (本番封鎖は STEP 9 で適用するため、ここでは最小限のルールのみ)
_log "IP フォワーディングを有効化..."
sysctl net.inet.ip.forwarding=1

# OpenBSD はデフォルトで pf が無効 (pfctl -s info で確認可能)。
# `pfctl -f` はルールセットをロードするだけで pf 自体を有効化しないため、
# pf が無効なホストでは NAT もブロックも一切働かず、VM の送信パケットが
# プライベートアドレスのまま素通りしてしまう (実際に発生: ルールは正しく
# ロードされ全カウンタが Evaluations:0 のまま、VM → 1.1.1.1 が不通)。
# 既に有効な場合 pfctl -e は非ゼロ終了するため失敗を無視する。
_log "pf を有効化 (既に有効なら何もしない)..."
pfctl -e 2>/dev/null || true
if ! pfctl -s info | grep -q '^Status: Enabled'; then
	_die "pf の有効化に失敗しました (pfctl -s info で Status: Enabled になりません)"
fi
_ok "pf 有効化確認"

_log "暫定 PF ルールを適用 (NAT: VM → WAN)..."
# 注意: `cat | pfctl -f - <<PFEOF` は NG。
#   ヒアドキュメントは右辺 (pfctl) に渡るが left の cat は端末 stdin を待ちフリーズする。
#   正しくは pfctl に直接ヒアドキュメントを渡す。
pfctl -f - <<PFEOF
# プロビジョニング中の暫定 PF ルール
# NAT: VM → インターネット (OpenBSD ミラーからインストールセットを取得)
# :0 で egress の最初のアドレスのみを使う。"nat-to (egress)" のままだと
# egress に複数アドレス (DHCP autoconf 等) が乗っているホストで round-robin
# プールになり、リターンパケットが来ない側のアドレスに当たると NAT が
# 不通になる事故が起きる (実際に発生: vm-db が 1.1.1.1 に到達不可)。
match out on egress from { 10.0.1.0/24, 10.0.2.0/24, 10.0.3.0/24 } nat-to (egress:0)

set block-policy drop
set skip on lo0
block all

# SSH: 管理アクセスを維持 (Yubikey セットアップ完了まで維持する §yubikey-setup.sh)
# (sloppy) が必須: pf はそれまで無効だったため、この provision.sh 自体を
# 実行している既存 SSH 接続 (3 ウェイハンドシェイクを pf が見ていない) には
# state が無い。デフォルトの厳密な状態追跡は SYN パケットでしか新規 state を
# 作らないため、確立済み接続の ACK 続きパケットがどのルールにもマッチせず
# block all に落ちて切断される (実際に発生: STEP 4 で pf を有効化した瞬間、
# provision.sh を実行している SSH セッション自体が切れてスクリプトが
# 無言で死に「フリーズ」したように見えた)。sloppy は SYN を見ていない
# 既存接続でも途中から state を確立できるため、この遷移を安全にする。
pass in on egress proto tcp to port 22 keep state (sloppy)

# DHCP: DISCOVER は src=0.0.0.0/dst=255.255.255.255 のブロードキャスト。
# keep state はステートエントリに有効 src が必要なため 0.0.0.0 で作れず drop される。
# quick no state で先行許可することで stateful tracking を迂回する。
pass quick on tap     proto udp from any port 68 to any port 67 no state
pass quick on vether0 proto udp from any port 67 to any port 68 no state
pass quick on vether1 proto udp from any port 67 to any port 68 no state

# VM ↔ ホスト: その他の通信
# bridge(4) のフィルタリングはブリッジ本体ではなく各メンバーで行われる。
# bridge0/1/2 = 手動生成スイッチ, veb0/1/2 = vmd 自動生成スイッチ (両方許可)
# 内部スイッチは keep state 不要。no state で通す。
# (audit_lan もプロビジョニング中だけは pkg_add 等のため一時的に開ける。
#  本番封鎖後の audit_lan 制限は host/conf/pf.conf §6.1 が別途強制する)
pass on tap     all no state
pass on bridge0 all no state
pass on bridge1 all no state
pass on bridge2 all no state
pass on veb0    all no state
pass on veb1    all no state
pass on veb2    all no state
pass on vether0 all no state
pass on vether1 all no state
pass on vether2 all no state

# VM DNS → unwind (127.0.0.1:53) へリダイレクト
# install.conf の "DNS nameservers = gateway" を機能させる (STEP 3 で unwind 起動済み)
pass in quick on vether0 proto { udp tcp } from 10.0.1.0/24 to ${HOST_INT_IP} port 53 rdr-to 127.0.0.1
pass in quick on vether1 proto { udp tcp } from 10.0.2.0/24 to ${HOST_DEV_IP} port 53 rdr-to 127.0.0.1
pass in quick on vether2 proto { udp tcp } from 10.0.3.0/24 to ${HOST_AUDIT_IP} port 53 rdr-to 127.0.0.1

# VM → インターネット: インストールセット取得 / pkg_add / ソースビルド用
pass out on egress all keep state
PFEOF
_log "pfctl -s rules:"
pfctl -s rules 2>/dev/null | while read -r l; do _log "  $l"; done
_ok "暫定 PF (NAT) 適用"
