#!/bin/sh
# vm-build/setup.sh — Build VM セットアップ (GHC + cabal + Forgejo Runner)
# §3.1: owlv バイナリをビルドして Forgejo パッケージレジストリにアップロード
# GHC は OpenBSD ports から取得 (バージョンは owl-config.toml の toolchain.ghc_version)
# 実行: provision.sh の STEP 6 から SSH で呼び出す
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
GHC_VERSION="${GHC_VERSION:-9.6}"
FORGEJO_RUNNER_VERSION="3.5.0"

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

	mkdir -p "$RUNNER_SRC"
	tar xzf "${RUNNER_SRC}.tar.gz" -C "$RUNNER_SRC" --strip-components=1
	rm -f "${RUNNER_SRC}.tar.gz"

	(cd "$RUNNER_SRC" && go build -o "$RUNNER_BIN" .) ||
		_die "Forgejo Runner のビルドに失敗しました"

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
