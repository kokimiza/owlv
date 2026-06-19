#!/bin/sh
# yubikey-setup.sh — Yubikey PIV による SSH 認証強化
# §5: 物理デバイス認証の追加 (パスワード認証の全廃)
#
# 【実行タイミング】Yubikey 到着後、現在の SSH セッションから実行:
#   ssh <YOUR_USERNAME>@192.168.50.200 'doas sh /etc/owl/infra/host/security/yubikey-setup.sh'
#
# 【前提条件】
#   - ykman がインストール済み (pkg_add yubico-piv-tool)
#   - Yubikey が物理的に挿入されている
#   - すでにパスフレーズ付き SSH 鍵でログインできる状態
set -eu

_log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
_die() {
	_log "エラー: $*" >&2
	exit 1
}
_info() { _log "    $*"; }

[ "$(id -u)" -eq 0 ] || _die "root (doas) で実行してください"

# ── Yubikey 確認 ─────────────────────────────────────────
_log "Yubikey を確認中..."
ykman list 2>/dev/null | grep -i 'yubikey' || _die "Yubikey が検出されません。挿入されているか確認してください"
SERIAL="$(ykman list 2>/dev/null | awk '{print $NF}' | head -1)"
_info "シリアル番号: ${SERIAL}"

# ── PIV スロット 9a に P-384 鍵を生成 ─────────────────────
_log "PIV スロット 9a に鍵を生成します"
_info "Yubikey の Management Key (デフォルト: 010203040506070801020304050607080102030405060708) を入力します"
_info "本番運用前に Management Key を必ず変更してください: ykman piv access change-management-key"

# 公開鍵を一時ファイルに保存
PIV_PUB="$(mktemp /tmp/yk-piv-pub.XXXXXX.pem)"
trap 'rm -f "$PIV_PUB"' EXIT

ykman piv keys generate \
	--algorithm ECCP384 \
	--touch-policy always \
	--pin-policy always \
	9a "$PIV_PUB" ||
	_die "PIV 鍵生成に失敗しました。ykman piv access verify-pin で PIN を確認してください"

_info "PIV 鍵生成完了 (P-384, touch+pin required)"

# 自己署名証明書を生成 (SSH 認証には不要だが PIV スロットには必須)
ykman piv certificates generate \
	--subject "CN=owl-admin,O=owlv" \
	9a "$PIV_PUB" ||
	_die "PIV 証明書生成に失敗しました"

_info "PIV 証明書生成完了"

# ── SSH 公開鍵の抽出 ─────────────────────────────────────
_log "SSH 公開鍵を抽出中..."
SSH_PUB="$(ssh-keygen -i -m pkcs8 -f "$PIV_PUB" 2>/dev/null ||
	ykman piv keys export 9a - 2>/dev/null | ssh-keygen -i -m pkcs8 -f /dev/stdin)"

# 代替手段: ykman で直接 SSH 公開鍵を抽出
if [ -z "${SSH_PUB:-}" ]; then
	SSH_PUB="$(ykman piv keys export --format ssh 9a - 2>/dev/null)" ||
		_die "SSH 公開鍵の抽出に失敗しました。'ykman piv keys export --format ssh 9a -' を手動で実行してください"
fi

_info "SSH 公開鍵:"
_info "  ${SSH_PUB}"

# ── authorized_keys に追加 ──────────────────────────────
_log "authorized_keys を更新します"

# /etc/ssh/authorized_keys/<user> または ~/.ssh/authorized_keys を更新
# OpenBSD のデフォルト sshd_config は AuthorizedKeysFile を参照
for AK_FILE in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
	[ -f "$AK_FILE" ] || continue
	if grep -qF "$SSH_PUB" "$AK_FILE" 2>/dev/null; then
		_info "  ${AK_FILE}: 既に登録済み"
	else
		echo "$SSH_PUB sk-ecdsa-sha2-nistp384@openssh.com yubikey-${SERIAL}" >>"$AK_FILE"
		_info "  ${AK_FILE}: 追加完了"
	fi
done

# ── 接続テスト (インタラクティブ確認) ─────────────────────
_log "Yubikey 認証をテストします"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " 【重要】パスワード認証を無効化する前に以下を確認してください。"
echo ""
echo " 別のターミナルを開いて Yubikey を使って SSH 接続してください:"
echo "   ssh -i ~/.ssh/id_ecdsa_sk <YOUR_USERNAME>@192.168.50.200"
echo "   (ykman を使っている場合は PKCS11 経由)"
echo ""
echo " 接続が成功しましたか？ [yes/no]"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "> "
read -r CONFIRMED

if [ "$CONFIRMED" != "yes" ]; then
	_log "接続テスト未確認。パスワード認証は維持します。"
	_log "Yubikey 認証を確認後に再実行してください。"
	exit 0
fi

# ── パスワード認証を無効化 ───────────────────────────────
_log "パスワード認証を無効化します"

# 既存の sshd_config を更新
sed -i \
	-e 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' \
	-e 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
	-e 's/^#*KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' \
	/etc/ssh/sshd_config

# sshd_config.d にも適用
if [ -d /etc/ssh/sshd_config.d ]; then
	for conf in /etc/ssh/sshd_config.d/*.conf; do
		[ -f "$conf" ] || continue
		sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "$conf"
	done
fi

sshd -t || _die "sshd_config の構文エラー。変更を確認してください"
rcctl restart sshd
_info "パスワード認証無効化完了"

# ── オプション: sshd を完全無効化 ───────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " sshd を完全無効化しますか？"
echo " (無効化後は物理コンソールまたは Yubikey FIDO2 のみでアクセス可能)"
echo " [yes/no]"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "> "
read -r DISABLE_SSHD

if [ "$DISABLE_SSHD" = "yes" ]; then
	rcctl disable sshd
	# rc.conf.local を sshd=NO に更新
	sed -i 's/^sshd=.*/sshd=NO/' /etc/rc.conf.local 2>/dev/null ||
		echo 'sshd=NO' >>/etc/rc.conf.local
	_log "sshd を無効化しました。次回起動時から sshd は起動しません"
else
	_log "sshd は有効なまま維持します"
fi

_log "Yubikey セットアップ完了"
echo ""
echo " 【Management Key の変更を忘れずに】"
echo "   ykman piv access change-management-key --generate --protect"
echo ""
echo " 【PIN の変更を忘れずに】"
echo "   ykman piv access change-pin"
