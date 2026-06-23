#!/bin/sh
# vm-audit/setup.sh — Audit VM セットアップ (syslog 集約 / 改ざん検知 / 外部通報)
# doc/dev_sec_ops.md §6: 特権侵害の検知と隔離。ネットワーク層の片方向強制は
# host/conf/pf.conf が担い、本スクリプトはこの VM 自身の受信・保管・検知・
# 通報・自己防衛 (§6.2, §6.3) のみを扱う。
# 実行: provision.sh の STEP 8 から SSH で呼び出す
set -eu

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_info() { _log "    $*"; }
_ok() { _log "  ✓ $*"; }

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"

OWL_AUDIT_IP="${OWL_AUDIT_IP:?OWL_AUDIT_IP is required}"
# webhook URL は未確定の場合がある (owl-config.toml [audit].notify_webhook_url)。
# 空のままでも検知自体は行い、ログに記録する。送信だけを無効化する安全側デフォルト。
NOTIFY_WEBHOOK_URL="${OWL_AUDIT_NOTIFY_WEBHOOK:-}"

_log "Audit VM セットアップ開始 (${OWL_AUDIT_IP})"

# ── パッケージ ────────────────────────────────────────────
# curl: 検知スクリプトが webhook へ JSON を POST するために使用 (ftp(1) では
# 任意ヘッダ付き POST が困難)。webhook 未確定の現時点でも、確定時に再設定不要
# にするため先にインストールしておく。
_log "パッケージインストール"
pkg_add curl 2>/dev/null || _info "警告: curl のインストールに失敗。後で手動実行: pkg_add curl"
_ok "パッケージ"

# ── ログ受信ディレクトリ ────────────────────────────────────
install -d -m 750 -o root -g wheel /var/log/audit
_ok "/var/log/audit 作成"

# ── syslogd: 他 VM / ホストからの auth.* を受信 ──────────────────
# OpenBSD syslogd は既定で UDP/514 のネットワーク受信を有効にしている (無効化
# したい場合のみ -s)。送信元の絞り込みは host/conf/pf.conf が担うため、ここでは
# 受信した内容の振り分けのみを行う。送信元はすべて auth.* に絞って転送してくる
# 設計 (§6.1 鉄則②) のため、ここでは追加のフィルタリングは行わず全件を専用
# ファイルへ書き出す。
grep -qF '/var/log/audit/remote.log' /etc/syslog.conf 2>/dev/null || {
	printf '*.*\t\t\t\t\t/var/log/audit/remote.log\n' >>/etc/syslog.conf
	_ok "syslog.conf に /var/log/audit/remote.log 振り分けを追加"
}
install -d -m 750 /var/log/audit
[ -f /var/log/audit/remote.log ] || install -m 640 /dev/null /var/log/audit/remote.log
rcctl enable syslogd
rcctl restart syslogd
_ok "syslogd 再起動 (UDP/514 受信)"

# ── newsyslog: 稼働中ログは素のローテーション ───────────────────
# 【重要】schg/sappnd は稼働中ファイルに付けない。OpenBSD では schg も sappnd も
# root 権限下でも mv/truncate を一切受け付けないため、稼働中ファイルに付けると
# newsyslog のローテーション(リネーム→新規作成)自体がカーネルレベルで失敗し、
# ログ肥大化とディスク枯渇を招く(doc/dev_sec_ops.md §6.3)。確定済みの過去ログに
# 対してのみ owl-audit-seal.sh が事後的に sappnd を付与する。
grep -qF '/var/log/audit/remote.log' /etc/newsyslog.conf 2>/dev/null || {
	printf '/var/log/audit/remote.log\troot:wheel\t640\t30\t1024\t*\tB\n' >>/etc/newsyslog.conf
	_ok "newsyslog.conf にローテーション設定を追加 (30世代, gzip)"
}

# ── 確定済みログの封印 (sappnd) とハッシュチェーン ──────────────────
# newsyslog がローテーションした直後の過去ログ (remote.log.0.gz 等) にのみ
# sappnd を付与し、追記専用化する。アクティブな remote.log には触れない。
# ハッシュチェーンは Audit VM 内に閉じた記録であり、侵害後のフォレンジック時に
# 「いつどのログが封印され、その時点でのハッシュは何か」を後から検証するための
# ものである(ホストから能動的に読みに行く経路は鉄則①により存在しないため、
# ホスト側からの突合は行わない — host/security 側の物理コンソール対応時に
# このVM上で直接確認する)。
install -m 700 /dev/null /usr/local/sbin/owl-audit-seal.sh
cat >/usr/local/sbin/owl-audit-seal.sh <<'SEALEOF'
#!/bin/sh
# owl-audit-seal.sh — ローテーション済みログの封印 + ハッシュチェーン記録
# cron で定期実行 (vm-audit/setup.sh が登録)
set -eu
LOGDIR=/var/log/audit
CHAIN=/var/log/audit/sealed-manifest.sha256

for f in "${LOGDIR}"/remote.log.*.gz; do
	[ -f "$f" ] || continue
	# すでに sappnd 済み(= 封印済み)のものは再処理しない
	# ls -lo の列順: mode links owner flags size month day time name
	flags="$(ls -lo "$f" 2>/dev/null | awk '{print $4}')"
	case "$flags" in
	*sappnd*) continue ;;
	esac
	hash="$(sha256 -q "$f")"
	prev="$(tail -1 "$CHAIN" 2>/dev/null | awk '{print $3}')"
	printf '%s\t%s\t%s\tprev=%s\n' "$(date -u +%FT%TZ)" "$f" "$hash" "${prev:-GENESIS}" >>"$CHAIN"
	chflags sappnd "$f"
done
SEALEOF
chmod 700 /usr/local/sbin/owl-audit-seal.sh
[ -f /var/log/audit/sealed-manifest.sha256 ] || install -m 640 /dev/null /var/log/audit/sealed-manifest.sha256
_ok "owl-audit-seal.sh 配置"

# ── 検知スクリプト (§6.2) ───────────────────────────────────
# sudo/su の失敗連続・未承認 IP からの SSH ログイン成功・pf.conf ハッシュの
# §5 期待値からの乖離(ホストの owl-integrity-check.sh が auth.warning で
# logger 出力したものがここに転送されてくる、tag=owl-integrity)を検知する。
# 検知から通報までを単一プロセス内で完結させ、外部キューや中間サーバーを
# 経由しない(中間段がそれ自体踏み台になることを避ける、§6.2)。
# 【検証注記】sudo/su の失敗メッセージの正確な文字列は OpenBSD のバージョンや
# 認証方式により変わり得る。実機導入時に /var/log/audit/remote.log の実際の
# 出力を確認し、必要ならパターンを調整すること。
install -m 700 /dev/null /usr/local/sbin/owl-audit-detect.sh
cat >/usr/local/sbin/owl-audit-detect.sh <<'DETECTEOF'
#!/bin/sh
# owl-audit-detect.sh — リアルタイム検知 + 外部通報 (cron で1分間隔実行)
set -eu
LOG=/var/log/audit/remote.log
STATE=/var/run/owl-audit-detect.offset
WEBHOOK_FILE=/etc/owlv/audit-notify-webhook
LOGTAG=owl-audit-detect

[ -f "$LOG" ] || exit 0
cur_size=$(stat -f %z "$LOG" 2>/dev/null || echo 0)
last_off=$(cat "$STATE" 2>/dev/null || echo 0)

# ログがローテーションでリセットされた(現在サイズ < 前回オフセット)場合は
# オフセットを0から再開する。
if [ "$cur_size" -lt "$last_off" ]; then
	last_off=0
fi

chunk="$(tail -c "+$((last_off + 1))" "$LOG" 2>/dev/null || true)"
echo "$cur_size" >"$STATE"
[ -n "$chunk" ] || exit 0

ALERT=""

# 1) sudo/su の認証失敗が同一チャンク内に3回以上
fail_n=$(printf '%s\n' "$chunk" | grep -Eic 'authentication failure|incorrect password|BAD SU' || true)
[ "$fail_n" -ge 3 ] 2>/dev/null && ALERT="${ALERT}privilege-escalation-failures:${fail_n} "

# 2) SSH ログイン成功 (Accepted) — 検知のみ。許可IPの判定はネットワーク層
#    (host/conf/pf.conf) に委ねているため、ここでは「発生した」事実を記録する。
ssh_ok_n=$(printf '%s\n' "$chunk" | grep -c 'sshd.*Accepted' || true)
[ "$ssh_ok_n" -ge 1 ] 2>/dev/null && ALERT="${ALERT}ssh-login-success:${ssh_ok_n} "

# 3) ホストの owl-integrity-check.sh が転送する pf.conf 改ざん検知アラート
if printf '%s\n' "$chunk" | grep -q 'owl-integrity'; then
	ALERT="${ALERT}pf-conf-drift-detected "
fi

[ -n "$ALERT" ] || exit 0
logger -p auth.warning -t "$LOGTAG" "検知: ${ALERT}"

WEBHOOK_URL=""
[ -f "$WEBHOOK_FILE" ] && WEBHOOK_URL="$(cat "$WEBHOOK_FILE")"
if [ -z "$WEBHOOK_URL" ]; then
	logger -p auth.warning -t "$LOGTAG" "通報先 webhook 未設定のため外部通報は送信しません: ${ALERT}"
	exit 0
fi

# §6.1 鉄則③: 送信先は host/conf/pf.conf の <audit_notify_dst> テーブルで
# 既に固定済み。ここでは webhook の URL に対して POST するだけでよい。
curl -fsS -X POST -H 'Content-Type: application/json' \
	-d "{\"text\":\"[owlv audit] ${ALERT}\"}" \
	"$WEBHOOK_URL" >/dev/null 2>&1 ||
	logger -p auth.warning -t "$LOGTAG" "webhook 送信に失敗しました: ${ALERT}"
DETECTEOF
chmod 700 /usr/local/sbin/owl-audit-detect.sh
_ok "owl-audit-detect.sh 配置"

# webhook URL の配置 (owl-config.toml [audit].notify_webhook_url が空なら
# ファイル自体を作らない — owl-audit-detect.sh は未設定として扱う)
install -d -m 700 /etc/owlv
if [ -n "$NOTIFY_WEBHOOK_URL" ]; then
	printf '%s' "$NOTIFY_WEBHOOK_URL" >/etc/owlv/audit-notify-webhook
	chmod 600 /etc/owlv/audit-notify-webhook
	_ok "webhook URL を /etc/owlv/audit-notify-webhook に配置"
else
	rm -f /etc/owlv/audit-notify-webhook
	_info "webhook URL が owl-config.toml で未設定のため、検知のみ行い外部通報はしません"
	_info "確定したら owl-config.toml の [audit].notify_webhook_url と"
	_info "notify_dest_cidrs (host/conf/pf.conf §6.1鉄則③) を設定し、再プロビジョニングしてください"
fi

# ── cron 登録 ────────────────────────────────────────────
crontab -l 2>/dev/null | grep -v 'owl-audit-' >/tmp/owl-audit-crontab.tmp || true
{
	cat /tmp/owl-audit-crontab.tmp
	echo "* * * * * /usr/local/sbin/owl-audit-detect.sh >/dev/null 2>&1"
	echo "*/10 * * * * /usr/local/sbin/owl-audit-seal.sh >/dev/null 2>&1"
} | crontab -
rm -f /tmp/owl-audit-crontab.tmp
_ok "cron 登録 (検知: 1分間隔 / 封印: 10分間隔)"

# ── プロビジョニング完了処理 (ロックダウン前に自己完結させる) ──────────
# 直後に適用する pf.conf は SSH(22) の受信を許可しないため、host/steps/08-vm-provision.sh
# が他 VM と同様に行う「完了マーカーの書き込み」「プロビジョニング鍵の削除」を
# SSH 経由で事後に行うことができない (実際に発生: ssh connect timed out)。
# 鉄則① (host から audit VM への能動的な読み込み経路を持たない) は意図的な設計
# のため、ここでロックダウン前に自分自身で済ませておく。host 側はこの VM に対して
# のみ該当の事後 SSH 呼び出しをスキップする。
date >/provision/.owl-provisioned
if [ -f /root/.ssh/authorized_keys ]; then
	grep -v 'owl-prov-' /root/.ssh/authorized_keys >/root/.ssh/ak.tmp || true
	mv /root/.ssh/ak.tmp /root/.ssh/authorized_keys
	chmod 600 /root/.ssh/authorized_keys
fi
_ok "完了マーカー配置 + プロビジョニング鍵削除 (ロックダウン前に自己処理)"

# ── このVM自身の pf (防御縦深、§6.3) ─────────────────────────
# ネットワーク層の片方向強制の本体は host/conf/pf.conf(ホスト側)であり、
# これはあくまで二重防御。ゲスト自身も default-deny にしておく。
cat >/etc/pf.conf <<'PFEOF'
# vm-audit 自身の pf.conf (§6.3) — ホスト側 pf.conf による隔離の二重防御
set block-policy drop
set skip on lo0
block all
pass in proto udp to port 514
pass out proto tcp to port 443
PFEOF
pfctl -f /etc/pf.conf
rcctl enable pf
_ok "ゲスト pf.conf 適用"

# ── 自己防衛: schg + securelevel (§6.3) ──────────────────────
# securelevel >= 1 は OpenBSD の multiuser 起動で既定で設定される。明示的に
# /etc/rc.securelevel へ書いておくことで、将来の設定変更で 0 に戻されても
# 復元されるようにする。schg は securelevel >= 1 でのみ「外せない」状態になる
# ため、この VM が侵害されても /etc/pf.conf と /etc/newsyslog.conf の書き換えは
# シングルユーザーモードへの再起動を経ない限り拒否される。
cat >/etc/rc.securelevel <<'SLEOF'
# /etc/rc.securelevel — multiuser 起動時に実行される (rc(8))
sysctl kern.securelevel=1
SLEOF
chmod 644 /etc/rc.securelevel
sysctl kern.securelevel=1 2>/dev/null || _info "securelevel は次回起動時に適用されます (現在の状態からは上げられない場合がある)"

chflags schg /etc/pf.conf
chflags schg /etc/newsyslog.conf
_ok "schg 適用: /etc/pf.conf /etc/newsyslog.conf"

_log "Audit VM セットアップ完了"
echo ""
echo " 【残りの手動作業】"
echo "   1. webhook URL が未確定の場合: owl-config.toml の [audit] を編集後、"
echo "      再プロビジョニング(本スクリプトは再実行可能)で /etc/owlv/audit-notify-webhook を配置"
echo "   2. host/conf/pf.conf の <audit_notify_dst> 用 CIDR ([audit].notify_dest_cidrs)"
echo "      も webhook 確定時に設定し、host/steps/09-lockdown.sh の再実行で反映すること"
