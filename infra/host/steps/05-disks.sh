# shellcheck shell=ksh
# step 05 — VM ディスクイメージ作成
_step 5 "VM ディスクイメージ作成"
_log "ディスクイメージディレクトリ: /var/vmm"
install -d -m 755 /var/vmm
for spec in "ap:20G" "db:50G" "git:50G" "build:50G"; do
	name="${spec%%:*}"
	size="${spec##*:}"
	img="/var/vmm/${name}.img"
	if [ ! -f "$img" ]; then
		_log "${name}.img (${size}) を作成中..."
		vmctl create -s "$size" "$img" && _ok "${name}.img (${size}) 作成"
	else
		_log "${name}.img 既存 ($(du -h "$img" | cut -f1)) → スキップ"
		_info "${name}.img 既存のためスキップ"
	fi
done

# 完全な vm.conf の配置と reload は、競合を防ぐため STEP 7 のインストール完了後（またはSTEP 9）に後回しにします。
_ok "VM ディスクイメージ準備完了"
