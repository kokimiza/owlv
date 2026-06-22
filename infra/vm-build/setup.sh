#!/bin/sh
# vm-build/setup.sh — Build VM セットアップ (GHC + cabal + Forgejo Runner)
# §3.1: owlv バイナリをビルドして Forgejo パッケージレジストリにアップロード
# GHC は OpenBSD ports から取得 (バージョンは owl-config.toml の toolchain.ghc_version)
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

OWL_BUILD_IP="${OWL_BUILD_IP:?OWL_BUILD_IP is required}"
OWL_GIT_IP="${OWL_GIT_IP:?OWL_GIT_IP is required}"
FORGEJO_RUNNER_SECRET="${FORGEJO_RUNNER_SECRET:?FORGEJO_RUNNER_SECRET is required}"
# GHC2024 (base ^>= 4.20 / GHC >= 9.10) を要求する。OpenBSD の packages/amd64
# はリリース内でも point release ごとに古いバージョン名の .tgz を消す
# (実際に発生: まず "Can't find ghc-9.6"、その後 "Can't find ghc-9.10.1" も
# 発生)。pkg_add のターゲットをパッケージのフルバージョンで固定すると
# 必ずいつか壊れるので、無印の ghc (= packages/amd64 にある現行版) を入れ、
# 実際にインストールされたバージョンが GHC2024 の要件を満たすか事後確認する。
GHC_MIN_VERSION="${GHC_VERSION:-9.10}"
FORGEJO_RUNNER_VERSION="${FORGEJO_RUNNER_VERSION:-12.11.1}"

_log "Build VM セットアップ開始 (${OWL_BUILD_IP})"

# ── パッケージ (GHC / cabal / 依存) ─────────────────────
_log "GHC (>= ${GHC_MIN_VERSION}) および開発ツールをインストール"
# GHC は ports から (バイナリパッケージとして提供)
pkg_add ghc cabal-install git curl ||
	_die "GHC のインストールに失敗しました。上記 pkg_add の出力を確認してください"

_installed_ghc=$(pkg_info | awk '/^ghc-[0-9]/{print $1; exit}' | sed -E 's/^ghc-([0-9]+\.[0-9]+).*/\1/')
[ -n "$_installed_ghc" ] || _die "インストールされた GHC のバージョンを判定できませんでした (pkg_info の出力を確認してください)"

awk -v have="$_installed_ghc" -v need="$GHC_MIN_VERSION" 'BEGIN{
		split(have, h, "."); split(need, n, ".");
		hv = h[1] * 1000 + h[2]; nv = n[1] * 1000 + n[2];
		exit (hv >= nv) ? 0 : 1
	}' ||
	_die "インストールされた GHC ${_installed_ghc} は GHC2024 要件 (>= ${GHC_MIN_VERSION}) を満たしません。OpenBSD ${OWL_RELEASE:-該当} の packages/amd64 にそれ以上の ghc パッケージが無い可能性があります"
_ok "GHC ${_installed_ghc} / cabal / git"

# cabal のキャッシュ ($HOME/.cabal = /root/.cabal) は go の GOPATH/GOCACHE と
# 同じ理由で "/" を圧迫する (実際に発生: Hackage インデックス取得後の
# useradd で "/etc/spwd.db: No space left on device")。さらに "_build" と
# いう専用ユーザーはこのスクリプトのどこにも作成されておらず su は常に失敗し、
# 結局 root (/root/.cabal) で実行されていた。go と同様に /usr/local 配下へ
# 明示的に退避する。
export CABAL_DIR=/usr/local/cabal-data
install -d "$CABAL_DIR"
_info "cabal update"
cabal update 2>/dev/null || true

# owlv の依存パッケージ。リードモデル (doc/cqrs.md) の direct-sqlite は
# bundled amalgamation を静的コンパイルするため (systemlib フラグ既定 False)、
# ビルドに system の libsqlite3 は不要。ここでの sqlite3 パッケージは
# .sqlite3 ファイルを直接調査するための CLI ツール用途のみ (doc/cqrs.md §7)。
pkg_add sqlite3 2>/dev/null ||
	_info "警告: sqlite3 が見つかりません。手動でインストールしてください: pkg_add sqlite3"

# ── HLint (CI の Sec ゲート、doc/dev_sec_ops.md §4.1①で使用) ──────────
# OpenBSD ports に hlint パッケージは無いため cabal でビルドする。
# ビルド成果のみ /usr/local/bin へ複製し、ビルド用キャッシュは cabal の
# 通常キャッシュ ($CABAL_DIR) に残る (go の forgejo/forgejo-runner ビルドとは
# 違い、hlint 自体は owlv のビルドキャッシュと共存させて再ビルドを避ける)。
if ! command -v hlint >/dev/null 2>&1; then
	_log "HLint をインストール"
	cabal install hlint --install-method=copy --installdir=/usr/local/bin --overwrite-policy=always ||
		_die "HLint のインストールに失敗しました"
	_ok "HLint: $(hlint --version 2>/dev/null | head -1)"
else
	_info "HLint: 既存のためスキップ"
fi

# ── リリース署名鍵 (signify, doc/dev_sec_ops.md §4.2 三重検証の「タグ署名」) ──
# CI が生成する manifest.txt (タグ/コミット/uname -r/各バイナリのSHA256) に
# signify で署名し、AP VM 側 (owl-control.sh cmd_deploy) が公開鍵で検証する。
# GPG ではなく signify を使うのは、本プロジェクトが脆弱性DB同期(§4.1①)でも
# signify を第一選択としているのと同じ理由 (OpenBSD ネイティブの検証経路)。
# CI は無人実行のためパスフレーズ無し (-n) で鍵を生成する。秘密鍵は
# Forgejo Runner の実行ユーザー (_runner) のみが読めるようにする。
SIGNIFY_SEC=/etc/owlv/release-signify.sec
SIGNIFY_PUB=/etc/owlv/release-signify.pub
if [ ! -f "$SIGNIFY_SEC" ]; then
	_log "リリース署名鍵 (signify) を生成"
	install -d -m 750 -o _runner /etc/owlv
	signify -G -n -p "$SIGNIFY_PUB" -s "$SIGNIFY_SEC" ||
		_die "signify 鍵の生成に失敗しました"
	chown _runner "$SIGNIFY_SEC" "$SIGNIFY_PUB"
	chmod 600 "$SIGNIFY_SEC"
	chmod 644 "$SIGNIFY_PUB"
	_ok "signify 鍵: ${SIGNIFY_PUB}"
else
	_info "signify 鍵: 既存のためスキップ"
fi

# ── Forgejo Runner (OpenBSD: ソースからビルド) ───────────────────
# 公式リリースは linux-amd64 / linux-arm64 のみ。OpenBSD では go build が必要 (§3.1)。
# 純粋 Go 実装のため Node.js 等の追加依存は不要。
_log "Forgejo Runner ${FORGEJO_RUNNER_VERSION} をソースからビルド"
RUNNER_BIN="/usr/local/bin/forgejo-runner"
RUNNER_SRC="/tmp/forgejo-runner-build"

if [ ! -f "$RUNNER_BIN" ]; then
	pkg_add go 2>/dev/null || _die "go のインストールに失敗しました"

	ftp -o "${RUNNER_SRC}.tar.gz" \
		"https://code.forgejo.org/forgejo/runner/archive/v${FORGEJO_RUNNER_VERSION}.tar.gz" ||
		_die "Forgejo Runner ソースのダウンロードに失敗しました (v${FORGEJO_RUNNER_VERSION})"

	# OpenBSD 標準の tar は GNU 拡張の --strip-components を解釈できず、
	# フラグそのものを展開対象パターンとして扱って "patterns were not
	# matched" になる (実際に発生、vm-git/setup.sh と同種)。アーカイブの
	# トップレベルディレクトリを一旦別の場所に展開し、それ自体を目的の
	# パスへ rename することで同等の効果を得る。
	mkdir -p "${RUNNER_SRC}.extract"
	tar xzf "${RUNNER_SRC}.tar.gz" -C "${RUNNER_SRC}.extract"
	rm -f "${RUNNER_SRC}.tar.gz"
	_runner_top=$(find "${RUNNER_SRC}.extract" -mindepth 1 -maxdepth 1 -type d | head -1)
	[ -n "$_runner_top" ] || _die "Forgejo Runner ソース展開後にトップレベルディレクトリが見つかりません"
	rm -rf "$RUNNER_SRC"
	mv "$_runner_top" "$RUNNER_SRC"
	rmdir "${RUNNER_SRC}.extract" 2>/dev/null || true

	# go のモジュールキャッシュ ($HOME/go = /root/go) は OpenBSD インストーラーの
	# 自動パーティショニングで "/" に割り当てられる小さな領域に乗ってしまい、
	# 依存の肥大で容量を使い切る (実際に発生、vm-git/setup.sh と同種:
	# "no space left on device" で go build が失敗)。/usr は自動レイアウトで
	# 大きく確保される側のパーティションなので、そちら配下にキャッシュを移す。
	_log "GOPATH/GOCACHE を /usr/local 配下へ退避 (/ パーティション枯渇回避)"
	# 前回失敗時に /root/go へ書きかけたキャッシュが残っていると "/" を
	# 圧迫し続けるので、再実行時のために必ず破棄しておく
	rm -rf /root/go
	export GOPATH=/usr/local/go-workspace
	export GOCACHE=/usr/local/go-workspace/cache
	install -d "$GOPATH" "$GOCACHE"

	(cd "$RUNNER_SRC" && go build -o "$RUNNER_BIN" .) ||
		_die "Forgejo Runner のビルドに失敗しました"

	# ビルド専用キャッシュなので完了後は破棄してディスクを回収する
	rm -rf "$GOPATH"
	chmod 755 "$RUNNER_BIN"
	rm -rf "$RUNNER_SRC"
	_ok "forgejo-runner: ${RUNNER_BIN}"
else
	_info "forgejo-runner: 既存のためスキップ"
fi

# runner 専用ユーザー
id _runner >/dev/null 2>&1 ||
	useradd -m -d /var/forgejo-runner -s /sbin/nologin _runner
install -d -m 750 -o _runner /var/forgejo-runner
install -d -m 750 -o _runner /var/log/forgejo-runner

# runner 設定 (オフライン登録済み; .runner ファイルを別途生成する)
cat >/var/forgejo-runner/config.yml.template <<EOF
# forgejo-runner config.yml
# provision.sh によるオフライン登録フロー (§4.1):
#   git_vm:   forgejo forgejo-cli actions register --name vm-build --secret <hex>
#   build_vm: forgejo-runner create-runner-file --instance http://<GIT_IP>:3000 --secret <同じhex>

log:
  level: info

runner:
  file: .runner
  capacity: 2
  envs:
    CABAL_DIR: /var/forgejo-runner/.cabal
  timeout: 3h
  insecure: false
  fetch_timeout: 5s
  fetch_interval: 2s

cache:
  enabled: true
  dir: /var/forgejo-runner/.cache

host:
  workdir: /var/forgejo-runner/workdir
EOF
chown _runner /var/forgejo-runner/config.yml.template

# rc.d サービス (オフライン登録後に自動で起動する)
cat >/etc/rc.d/forgejo-runner <<'EOF'
#!/bin/ksh
daemon="/usr/local/bin/forgejo-runner"
daemon_user="_runner"
daemon_flags="daemon --config /var/forgejo-runner/config.yml"
daemon_logger="daemon.info"

. /etc/rc.d/rc.subr
rc_cmd $1
EOF
chmod 755 /etc/rc.d/forgejo-runner
# ── オフライン Runner 登録 (Web UI 不要) ─────────────────────
# vm-git/setup.sh で forgejo forgejo-cli actions register --labels 'openbsd,haskell'
# が完了している前提。ラベルはその登録時点でシークレットに紐づいてサーバー側に
# 確定済みであり、create-runner-file (オフライン登録、ネットワーク接続不要) は
# 同じシークレットに対応する .runner ファイルをローカルに生成するだけなので
# --labels は受け付けない (実際に発生: "unknown flag: --labels")。
_log "Forgejo Runner オフライン登録 (.runner ファイル生成)"
su -m _runner -c "cd /var/forgejo-runner && \
	forgejo-runner create-runner-file \
		--instance 'http://${OWL_GIT_IP}:3000' \
		--secret '${FORGEJO_RUNNER_SECRET}' \
		--name vm-build" ||
	_die "forgejo-runner create-runner-file に失敗しました"
_ok ".runner ファイル生成"

cp /var/forgejo-runner/config.yml.template /var/forgejo-runner/config.yml
chown _runner /var/forgejo-runner/config.yml

rcctl enable forgejo-runner
rcctl start forgejo-runner
_ok "Forgejo Runner 起動"

_log "Build VM セットアップ完了"
echo ""
echo " 【残りの手動作業】"
echo "   1. owlv リポジトリに .forgejo/workflows/build.yml を追加"
echo "   2. git push で CI トリガーを確認:"
echo "      Forgejo → owlv → Actions タブ"
echo "   3. リリース署名公開鍵を AP VM の /etc/owlv/release-signify.pub へ配置"
echo "      (owl-control.sh cmd_deploy の三重検証で使用、doc/dev_sec_ops.md §4.2):"
cat "$SIGNIFY_PUB"
