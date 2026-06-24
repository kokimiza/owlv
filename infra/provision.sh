#!/bin/sh
# shellcheck shell=ksh
# provision.sh — owlv ベアメタルリストア
#
# ━━━ 【事前準備】OpenBSD 手動インストール直後にやること ━━━━━━━━━━━━━━━━
#
# OpenBSD はデフォルトで root の SSH ログインを禁止している。
# provision.sh を送り込む前に、物理コンソール (またはインストール時) で
# 管理者アカウントを作成しておく必要がある。
#
# 1. root になる (OpenBSD はデフォルトで root SSH 不可。インストール時に設定した
#    root パスワードで su する):
#      su -
#
# 2. インストール時に作ったユーザーを wheel に追加する
#    (すでに存在するユーザーを管理者にする場合):
#      usermod -G wheel <YOUR_USERNAME>
#
#    または新規に管理者ユーザーを作る場合:
#      useradd -m -G wheel -s /bin/ksh <YOUR_USERNAME>
#      passwd <YOUR_USERNAME>
#
# 3. doas を有効化:
#      echo 'permit persist :wheel' > /etc/doas.conf
#
# 4. SSH 公開鍵の登録 (ホスト側で root として実行):
#
#    【各開発機で鍵を生成する (鍵がまだない場合)】
#    開発機 (手元の Mac / PC) それぞれで以下を実行。パスフレーズは必ず設定すること。
#    -C のコメントは「この鍵を作った開発機の名前＠接続先 IP」にすると後で判別しやすい。
#      ssh-keygen -t ed25519 -C "<この開発機の名前>@192.168.50.200"
#      # 例: ssh-keygen -t ed25519 -C "macbook-alice@192.168.50.200"
#      # 例: ssh-keygen -t ed25519 -C "thinkpad-bob@192.168.50.200"
#    生成された ~/.ssh/id_ed25519.pub の内容を手元に控えておく。
#.     # 例： ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7QNOXZKGBsPmvCwj4AJInjG7cnb0aRh5wKGxThygPz ketchup@192.168.50.200
#
#    【ホスト側で authorized_keys に追加する (root として実行)】
#    登録したい全員分を 1 行 1 鍵で書く。あとから追加する場合は >> で追記。
#      install -d -m 700 /home/<YOUR_USERNAME>/.ssh
#      vi /home/<YOUR_USERNAME>/.ssh/authorized_keys
#        # ssh-ed25519 AAAA... macbook-alice@192.168.50.200
#        # ssh-ed25519 AAAA... thinkpad-bob@192.168.50.200
#        # ssh-ed25519 AAAA... macbook-alice-work@192.168.50.200  ← 同一人物の別マシンも可
#      chmod 600 /home/<YOUR_USERNAME>/.ssh/authorized_keys
#      chown -R <YOUR_USERNAME> /home/<YOUR_USERNAME>/.ssh
#
#    【接続確認 (各開発機から)】
#      ssh <YOUR_USERNAME>@192.168.50.200    # パスフレーズを入力してログインできれば OK
#
# ━━━ 【実行手順】開発機から ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# 5. 時刻を合わせる (OCSP 検証が通らなくなるため必須):
#      ssh <YOUR_USERNAME>@192.168.50.200 'doas rdate -n pool.ntp.org'
#
#    macOS / OpenBSD どちらも openrsync を使う。
#    初回のみホスト側に openrsync を入れる (SSH ログイン後 1 回だけ):
#      doas pkg_add rsync
#
#   # (0) 【初回のみ】infra/sets/ に OpenBSD 7.9 amd64 インストールセットを用意する
#   #     以下のファイルがすべて揃っていること:
#   #       base79.tgz  comp79.tgz  bsd  bsd.mp  bsd.rd  SHA256  SHA256.sig  BUILDINFO
#   #     不足ファイルを取得する例:
#   #       mkdir -p infra/sets && curl -Z -o "infra/sets/#1" "https://cdn.openbsd.org/pub/OpenBSD/7.9/amd64/{base79.tgz,comp79.tgz,bsd,bsd.mp,bsd.rd,SHA256,SHA256.sig,BUILDINFO}"
#   #
#   #   【初回のみ】sets/ をホストへ転送 (大容量なので rsync の通常対象から除外している):
#   rsync -av --progress infra/sets/ <YOUR_USERNAME>@192.168.50.200:/tmp/infra/sets/
#
#   # (1) infra を /tmp/infra/ に同期 (初回以降は sets/ は除外)
#   rsync -av --progress --exclude='sets/' infra/ <YOUR_USERNAME>@192.168.50.200:/tmp/infra/
#
#   # (2) SSH ログイン後、/etc/owlv/infra/ に配置して実行
#   ssh <YOUR_USERNAME>@192.168.50.200
#   doas rm -rf /etc/owlv/infra/ && doas cp -r /tmp/infra/ /etc/owlv/infra/
#   doas sh /etc/owlv/infra/provision.sh
#
#   ※ 重要: 削除対象は必ず /etc/owlv/infra/ に限定すること。/etc/owlv/ 直下には
#     provision.sh が生成する SSH 鍵・known_hosts・改ざん検知ベースラインが
#     置かれている。"doas rm -rf /etc/owlv/" のように infra/ より上を消すと、
#     再デプロイのたびにこれらが全損する (過去に実際に発生した事故)。
#
#   ※ 再実行時は rsync だけ打てば差分だけ転送される。
#
# ━━━ 【Yubikey が届いたら】━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#   ssh <YOUR_USERNAME>@<HOST_IP> 'doas sh /etc/owlv/infra/host/security/yubikey-setup.sh'
#
# この時点では SSH を維持する。
# Yubikey セットアップ完了まで管理者がロックアウトされないようにするため。
#
# ━━━ 【鍵の全体像 — provision.sh 実行に必要な鍵は上記の1個だけ】━━━━━━━━━━━
#
# 「鍵がもう1個要るのでは？」と迷いやすいので、本システムに登場する SSH 鍵を
# 一覧にしておく。**provision.sh 自体を実行するために開発機で用意するのは
# 上記 (4) の1個のみ**。PROV_KEY (/etc/owlv/prov_ed25519, 使い捨て) と
# BACKUP_KEY (/etc/owlv/backup_ed25519, 恒久・owl-control.sh 用) はホストが
# STEP 6 (host/steps/06-sshkeys.sh) で自動生成するため、開発機側で何かを
# 用意する必要はない。
#
# 以下は provision.sh の範囲外で、必要になったときに初めて個別に用意する
# **別系統の鍵**(同一鍵の使い回しはしない — 用途ごとに鍵を分離する最小権限の
# 原則。doc/user.md §2.1 の「同一鍵を複数 UserId に登録しない」と同じ発想):
#
#   - **git-jump 用** (任意、開発メンバーを増やすとき): 各開発者が自分の鍵を
#     作り、host/security/dev-join.sh <username> <pubkey-file> で登録する
#     (infra/host/conf/git-jump-keys/<username>.pub としてコミットも忘れずに)。
#     Forgejo Web UI / git push へのトンネル専用、シェル到達不可。
#   - **fohlen UI 閲覧用** (任意、Audit VM の htmx UI を見るとき):
#     doc/audit_engine.md §6.2 の手順で developer ごとに
#     "restrict,permitopen=\"<audit_vm>:9090\"" 付きの専用鍵を生成し、
#     ホストの authorized_keys に追加する。ポート転送専用、シェル到達不可。
#     この鍵は (4) のホスト管理ログイン鍵とは意図的に別系統にする
#     (ホスト管理アクセスと Audit VM 閲覧アクセスの権限を分離するため)。
#   - **Yubikey PIV/FIDO2 鍵** (Yubikey 到着後): yubikey-setup.sh が (4) の
#     パスフレーズ鍵を置き換える形で追加登録する。最終的にパスワード/パスフレーズ
#     認証を全廃する移行先。
#
# まとめると、provision.sh を初めて流すだけなら追加の鍵は不要。上記3種は
# 「プロビジョニング後の運用を広げるとき」に初めて要る。

set -eu
trap '_on_exit $?' EXIT

# ── ヘルパー関数 ───────────────────────────────────────────
# 関数はログ設定より先に定義する (trap 発火時に未定義にならないよう)

_on_exit() {
	local rc="$1"
	if [ "$rc" -ne 0 ]; then
		printf '[%s] エラー終了 (exit %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$rc"
		echo ""
		echo "エラー終了 (exit $rc)。PF ルールを安全な暫定状態に維持します。"
		echo "ログ: ${LOGFILE:-'(未設定)'}"
		echo "再実行: sh /etc/owlv/infra/provision.sh"
	else
		printf '[%s] プロビジョニング正常終了\n' "$(date '+%Y-%m-%d %H:%M:%S')"
	fi
}

_die() {
	printf '[%s] FATAL: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
	exit 1
}
_step() { printf '\n━━━ [%s/%s] %s\n' "$1" "$TOTAL" "$2"; }
_ok() { printf '    ✓ %s\n' "$*"; }
_info() { printf '      %s\n' "$*"; }
_log() { printf '    [%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

_vmctl_status_to() {
	local out="$1" err="${1}.err"

	if vmctl status >"$out" 2>"$err"; then
		rm -f "$err"
		return 0
	fi

	# switch-only の /etc/vm.conf では VM 行が無く、環境によっては
	# ヘッダを出していても vmctl status が非 0 を返す。ヘッダが取れて
	# いれば vmd は応答しているものとして扱う。
	if grep -q 'OWNER.*STATE.*NAME' "$out" 2>/dev/null; then
		rm -f "$err"
		return 0
	fi

	return 1
}

_vmctl_status_ok() {
	local out="/tmp/owl-vmctl-status.$$"

	if _vmctl_status_to "$out"; then
		rm -f "$out" "${out}.err"
		return 0
	fi
	rm -f "$out" "${out}.err"
	return 1
}

_log_vmctl_status() {
	local prefix="$1" out="/tmp/owl-vmctl-status.$$"

	if _vmctl_status_to "$out"; then
		while read -r l; do _log "  ${prefix}${l}"; done <"$out"
		rm -f "$out" "${out}.err"
		return 0
	fi

	if [ -s "${out}.err" ]; then
		while read -r l; do _log "  ${prefix}${l}"; done <"${out}.err"
	fi
	rm -f "$out" "${out}.err"
	return 1
}

_bridge_members() {
	local ifn="$1" members

	members=$(ifconfig "$ifn" 2>/dev/null | awk '
        /^[[:space:]]+member:/ { printf "%s ", $2 }
        /^[[:space:]]+[[:alnum:]_]+[0-9]+[[:space:]]+flags=/ { printf "%s ", $1 }
    ')
	printf '%s\n' "${members:-'(なし)'}"
}

# ディスクイメージ作成・OS (再)インストール前のホスト側空き容量チェック。
# 実際に発生: ホスト側の空き容量が尽きた状態で vm-db の OS 再インストールを
# 行い、スパースイメージへの書き込みがホスト側で失敗 → ゲストカーネルパニック
# ("dump to dev ... not possible") → bsd.rd への無限リブートループになった。
# VM ディスクは sparse なので宣言サイズ (owl-config.toml の size=) ではなく
# 実消費が問題になる。事前に最低限の空きを確認し、足りなければゲストを
# クラッシュさせる前にここで止める。
_require_free_space() {
	local path="$1" min_gb="$2" avail_kb avail_gb
	avail_kb=$(df -k "$path" | awk 'NR==2{print $4}')
	avail_gb=$((avail_kb / 1024 / 1024))
	if [ "$avail_gb" -lt "$min_gb" ]; then
		_die "${path} の空き容量が ${avail_gb}G しかありません (${min_gb}G 以上が必要)。VM ディスクイメージの実消費を確認してください: du -sh ${path}/*.img"
	fi
	_info "${path} 空き容量: ${avail_gb}G (>= ${min_gb}G 必要)"
}

_vm_state_for() {
	local vmname="$1" out="/tmp/owl-vmctl-state.$$" state

	if _vmctl_status_to "$out"; then
		state=$(awk -v n="$vmname" 'NR>1 && $NF==n{print $(NF-1); exit}' "$out")
		rm -f "$out" "${out}.err"
		printf '%s\n' "$state"
		return 0
	fi
	rm -f "$out" "${out}.err"
	return 1
}

# ── ログファイル ───────────────────────────────────────────
# OpenBSD /bin/sh (pdksh 派生) はプロセス置換 >(cmd) 未サポート。
# named pipe + バックグラウンド tee で端末とファイルに同時出力する。
mkdir -p /var/log/owl
LOGFILE="/var/log/owlv/provision-$(date +%Y%m%d-%H%M%S).log"
_LOGPIPE="/tmp/owl-prov-$$.pipe"
mkfifo -m 600 "$_LOGPIPE"
tee -a "$LOGFILE" <"$_LOGPIPE" &
exec >"$_LOGPIPE" 2>&1
rm -f "$_LOGPIPE" # 名前を消してもプロセス間の fd は維持される
printf '[%s] ログ出力先: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LOGFILE"

[ "$(id -u)" -eq 0 ] || _die "root で実行してください"
[ "$(uname)" = "OpenBSD" ] || _die "OpenBSD でのみ実行可能"

_log "OS: $(uname -srm)  カーネル: $(sysctl -n kern.version | head -1)"
_log "ホスト: $(hostname)"

SELF="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${SELF}/owl-config.toml"
TOTAL=9
_log "provision.sh: ${SELF}/provision.sh checksum=$(cksum "$0" | awk '{print $1 ":" $2}')"

[ -f "$CONFIG" ] || _die "$CONFIG が見つかりません"

# ── TOML 読み込み ──────────────────────────────────────────
_toml() {
	awk -v sec="[$1]" -v k="$2" '
        /^\[/ { in_sec=($0==sec) }
        in_sec && $1==k {
            sub(/^[^=]+=[ ]*/, "")  # "key = " を除去
            sub(/[ ]*#.*$/, "")     # インラインコメント "# ..." を除去
            gsub(/^"|"$/, "")       # 前後の引用符を除去
            print; exit
        }
    ' "$CONFIG"
}

OWL_RELEASE=$(_toml "host" "openbsd_release")
WAN_IF=$(_toml "host" "wan_interface")
OWL_AP_IP=$(_toml "network.internal_lan" "ap_vm")
OWL_DB_IP=$(_toml "network.internal_lan" "db_vm")
OWL_GIT_IP=$(_toml "network.dev_lan" "git_vm")
OWL_BUILD_IP=$(_toml "network.dev_lan" "build_vm")
OWL_AUDIT_IP=$(_toml "network.audit_lan" "audit_vm")
GHC_VERSION=$(_toml "toolchain" "ghc_version")
PG_VERSION=$(_toml "app" "pg_version")
# 【修正】以前は [app] のうち pg_version だけが読み込まれ、同じセクションの
# ssh_port/db_name/db_*_user は一切 _toml で読まれずに 08-vm-provision.sh の
# 環境変数注入リストにも入っていなかった。vm-ap/setup.sh・vm-db/setup.sh は
# 各自のシェル側デフォルト値 (たまたま owl-config.toml の既定値と一致) に
# フォールバックしていたため実害は出ていなかったが、運用者が owl-config.toml
# を編集しても何も反映されない「死んだ設定」になっていた (実際に発生)。
APP_SSH_PORT=$(_toml "app" "ssh_port")
DB_NAME=$(_toml "app" "db_name")
DB_APP_USER=$(_toml "app" "db_app_user")
DB_REPL_USER=$(_toml "app" "db_repl_user")
DB_MIGRATOR_USER=$(_toml "app" "db_migrator_user")
DB_PLATFORM_ADMIN_USER=$(_toml "app" "db_platform_admin_user")
DB_PROJECTOR_USER=$(_toml "app" "db_projector_user")
FORGEJO_VER=$(_toml "forgejo" "version")
FORGEJO_RUNNER_VER=$(_toml "forgejo" "runner_version")
OWLV_ROOT_ADMIN_USERNAME=$(_toml "user" "root_admin_username")
OWL_AUDIT_NOTIFY_WEBHOOK=$(_toml "audit" "notify_webhook_url")
_log "設定読み込み完了:"
_log "  OWL_RELEASE=${OWL_RELEASE}  WAN_IF=${WAN_IF}"
_log "  internal_lan: AP=${OWL_AP_IP} DB=${OWL_DB_IP}"
_log "  dev_lan:      Git=${OWL_GIT_IP} Build=${OWL_BUILD_IP}"
_log "  audit_lan:    Audit=${OWL_AUDIT_IP}"
_log "  GHC=${GHC_VERSION}  PG=${PG_VERSION}  Forgejo=${FORGEJO_VER}  Runner=${FORGEJO_RUNNER_VER}"
_log "  app: ssh_port=${APP_SSH_PORT} db_name=${DB_NAME} db_app_user=${DB_APP_USER}"

LOGDIR=/var/log/owlv
HOST_INT_IP="10.0.1.1"
HOST_DEV_IP="10.0.2.1"
HOST_AUDIT_IP="10.0.3.1"
PROV_KEY=/etc/owlv/prov_ed25519     # プロビジョニング用の使い捨て SSH 鍵
BACKUP_KEY=/etc/owlv/backup_ed25519 # DR 用の恒久 SSH 鍵 (owl-control.sh が使用)

# Runner 登録シークレット: git_vm と build_vm で共有する (Web UI 不要のオフライン登録)
# § 4.1: forgejo forgejo-cli actions register / forgejo-runner create-runner-file
FORGEJO_RUNNER_SECRET=$(openssl rand -hex 20)
_log "Forgejo Runner シークレット生成完了 (40 文字 hex)"

export OWL_AP_IP OWL_DB_IP OWL_GIT_IP OWL_BUILD_IP OWL_AUDIT_IP \
	OWL_RELEASE GHC_VERSION PG_VERSION FORGEJO_VER FORGEJO_RUNNER_VER \
	FORGEJO_RUNNER_SECRET OWLV_ROOT_ADMIN_USERNAME OWL_AUDIT_NOTIFY_WEBHOOK \
	APP_SSH_PORT DB_NAME DB_APP_USER DB_REPL_USER DB_MIGRATOR_USER \
	DB_PLATFORM_ADMIN_USER DB_PROJECTOR_USER

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " owlv プロビジョニング! (OpenBSD ${OWL_RELEASE})"
echo " AP:${OWL_AP_IP}  DB:${OWL_DB_IP}"
echo " Git:${OWL_GIT_IP}  Build:${OWL_BUILD_IP}  Audit:${OWL_AUDIT_IP}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── ステップ実行 ───────────────────────────────────────────
STEPS_DIR="${SELF}/host/steps"

. "${STEPS_DIR}/01-host-foundation.sh"
. "${STEPS_DIR}/02-wan-network.sh"
. "${STEPS_DIR}/03-virt-bootstrap.sh"
. "${STEPS_DIR}/04-pf-nat.sh"
. "${STEPS_DIR}/05-disks.sh"
. "${STEPS_DIR}/06-sshkeys.sh"
. "${STEPS_DIR}/07-vm-install.sh"
. "${STEPS_DIR}/08-vm-provision.sh"
. "${STEPS_DIR}/09-lockdown.sh"

trap - EXIT

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " プロビジョニング完了 ✓"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " 【残作業】host/security/ の手順を順番に実行してください。"
echo " いずれもこの SSH セッションから直接実行可能 (sh /etc/owlv/infra/host/security/<script>):"
echo ""
echo "   1. ap-admin-user.sh      vm-ap に ${OWLV_ROOT_ADMIN_USERNAME:-<root_admin_username>} の"
echo "                            OS アカウントを作成 (owlv の初回 Admin 自動生成に必要)"
echo "   2. db-secrets-rotate.sh  vm-db の初期パスワードをローテーションし"
echo "                            vm-ap の db.env / db-ca.crt に伝播"
echo "   3. yubikey-setup.sh      Yubikey が届いたら実行 (SSH パスワード認証の全廃)"
echo ""
echo " 各スクリプトは何度でも再実行可能 (既に完了した分は検出してスキップする)。"
echo " 実行順を間違えても致命的ではないが、1→2 の順が前提を満たしやすい。"
echo ""
echo " 【開発メンバーを追加する場合】"
echo "   dev-join.sh <username> <pubkey-file> で git-jump アカウント (Forgejo Web UI /"
echo "   git push 専用、シェルなし) を追加。Web UI へは SSH ローカルポートフォワードで"
echo "   アクセスする (root/wheel での直接 SSH は使わない)。"
echo ""
echo " 【DR 復元の場合】"
echo "   age identity をエスクロー (§2.3) から取り出し"
echo "   射出先ストレージから最新アーカイブを取得・復号 (§2.4 手順5)"
