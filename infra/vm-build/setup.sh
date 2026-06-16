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

# ── Forgejo Runner ────────────────────────────────────────
_log "Forgejo Runner ${FORGEJO_RUNNER_VERSION} をインストール"
RUNNER_BIN="/usr/local/bin/forgejo-runner"
RUNNER_URL="https://code.forgejo.org/forgejo/runner/releases/download/v${FORGEJO_RUNNER_VERSION}/forgejo-runner-${FORGEJO_RUNNER_VERSION}-linux-amd64"

if [ ! -f "$RUNNER_BIN" ]; then
	ftp -o "$RUNNER_BIN" "$RUNNER_URL" ||
		_die "forgejo-runner のダウンロードに失敗しました"
	chmod 755 "$RUNNER_BIN"
	_ok "forgejo-runner: ${RUNNER_BIN}"
else
	_info "forgejo-runner: 既存のためスキップ"
fi

# runner 専用ユーザー
id _runner >/dev/null 2>&1 ||
	useradd -m -d /var/forgejo-runner -s /sbin/nologin _runner
install -d -m 750 -o _runner /var/forgejo-runner
install -d -m 750 -o _runner /var/log/forgejo-runner

# runner 設定テンプレート (トークンは Forgejo Web UI から手動で発行する)
cat >/var/forgejo-runner/config.yml.template <<EOF
# forgejo-runner config.yml
# トークン登録後に config.yml にコピーして使用する
# forgejo-runner register --no-interactive --instance http://${OWL_GIT_IP}:3000 --token <TOKEN> --name vm-build --labels 'openbsd,haskell'

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

# rc.d サービス (トークン登録後に手動で起動する)
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
# rcctl enable はトークン登録後に行う (今は起動しない)
_info "Forgejo Runner サービス登録 (トークン登録後に rcctl enable forgejo-runner)"

_log "Build VM セットアップ完了"
echo ""
echo " 【重要: 必ず手動で実施してください】"
echo "   1. Forgejo Web UI でRunner トークンを発行"
echo "      Settings → Actions → Runners → Create new runner"
echo "   2. トークンを登録:"
echo "      (vm-build で) forgejo-runner register \\"
echo "        --no-interactive \\"
echo "        --instance http://${OWL_GIT_IP}:3000 \\"
echo "        --token <TOKEN> \\"
echo "        --name vm-build \\"
echo "        --labels 'openbsd,haskell'"
echo "   3. Runner を有効化:"
echo "      rcctl enable forgejo-runner && rcctl start forgejo-runner"
echo "   4. owlv リポジトリに .forgejo/workflows/build.yml を追加"
