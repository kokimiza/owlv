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
# GHC2024 (base ^>= 4.20 / GHC >= 9.10) を要求する。OpenBSD 7.9
# (2026-05-19 リリース、現行) の packages/amd64 には ghc-9.10.1.tgz のみが
# 存在し (7.8 までの ghc-9.8.3 では base が古く GHC2024 を満たせない)、
# (実際に発生: "Can't find ghc-9.6")。
GHC_VERSION="${GHC_VERSION:-9.10.1}"
FORGEJO_RUNNER_VERSION="${FORGEJO_RUNNER_VERSION:-12.11.1}"

_log "Build VM セットアップ開始 (${OWL_BUILD_IP})"

# ── パッケージ (GHC / cabal / 依存) ─────────────────────
_log "GHC ${GHC_VERSION} および開発ツールをインストール"
# GHC は ports から (バイナリパッケージとして提供)
pkg_add "ghc-${GHC_VERSION}" cabal-install git curl 2>/dev/null ||
	pkg_add ghc cabal-install git curl 2>/dev/null ||
	_die "GHC のインストールに失敗しました。pkg_add ghc を手動で実行してください"
_ok "GHC / cabal / git"

# cabal パッケージインデックスを更新 (build 時ではなく今実行しておく)
_info "cabal update"
su -m _build -c "cabal update" 2>/dev/null ||
	cabal update 2>/dev/null || true

# owlv の依存パッケージ (brick, rocksdb-haskell, etc.)
# RocksDB C ライブラリが必要
pkg_add rocksdb 2>/dev/null ||
	_info "警告: rocksdb が見つかりません。手動でインストールしてください: pkg_add rocksdb"

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
# vm-git/setup.sh で forgejo forgejo-cli actions register が完了している前提。
# forgejo-runner create-runner-file はネットワーク接続なしで .runner ファイルを生成する。
_log "Forgejo Runner オフライン登録 (.runner ファイル生成)"
su -m _runner -c "cd /var/forgejo-runner && \
	forgejo-runner create-runner-file \
		--instance 'http://${OWL_GIT_IP}:3000' \
		--secret '${FORGEJO_RUNNER_SECRET}' \
		--name vm-build \
		--labels 'openbsd,haskell'" ||
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
