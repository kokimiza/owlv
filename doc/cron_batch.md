# OpenBSD サーバサイド cron 設定ガイド

## 前提

| 項目 | 値 |
|---|---|
| バイナリ配置 | `/usr/local/bin/owlv-batch-center` |
| 実行ユーザー | `_owlbatch`(専用サービスアカウント、UID 800) |
| ログディレクトリ | `/var/log/owl/` |
| ロックファイル置場 | `/var/run/owl/` |
| PG 接続 | libpq 環境変数 + `.pgpass` + TLS(verify-full) |
| バッチ実行 VM | AP VM(PG は DB VM、レジストリは Git VM に分離) |
| 信頼の根 | 内部 CA(PG / レジストリ共通) + signify 公開鍵 |

`_owlbatch` は nologin シェル、最小権限のサービスアカウント。doas では一切の昇格を許可しない（デフォルト拒否のまま）。owlv TUI 運用者とは権限境界を完全に分離する。

```sh
# グループを先に作る(useradd -g が参照するため順序が必要)
groupadd -g 800 _owlbatch

# UID < 1000 でシステムアカウント域に収める
useradd -u 800 -g _owlbatch -c "owlv batch runner" \
        -d /var/lib/owlbatch -s /sbin/nologin -m _owlbatch

# ホームは本人のみ(.pgpass・CA を置くため他者から読ませない)
chmod 700 /var/lib/owlbatch

# ログ・ロック領域(ディレクトリは root 管理、書き込みは _owlbatch)
install -d -o _owlbatch -g _owlbatch -m 750 /var/log/owl /var/run/owl
```

### 権限境界(doas.conf)

```
# /etc/doas.conf
# 既定は全拒否。_owlbatch には何の許可も書かない = 昇格不可。
# デプロイのみ、TUI 運用者グループ(owlops)に root 実行を許可する。
permit persist owlops as root cmd /usr/local/sbin/owlv-deploy-batch
```

`_owlbatch` に doas ルールを一行も書かないことが要点。バッチランナーが侵害されても、そこから root へ上がる経路は存在しない。Yubikey の物理タッチ強制は SSH(PIV)層で担保する（Rev.2 §1.2）。

---

## 1. 内部 PKI の整備(PG 接続とデプロイ fetch の共通前提)

§2 の PG 接続(`verify-full`)と §8 のデプロイ fetch(HTTPS)は、どちらも**内部 CA による証明書検証**が通らない限り初回接続から失敗する。ネットワーク設定より先に PKI を整備しないと、全バッチが exit 99 になる。

### 1-1. IP でなくホスト名で繋ぐ

`verify-full` は接続先ホスト名と証明書の CN/SAN を突合する。IP(`10.0.1.20`)で繋ぐ場合は証明書 SAN に `IP:10.0.1.20` が必要で、IP 変更のたびに再発行が要る。内部ホスト名を割り当て、`/etc/hosts` で解決させるほうが運用が固い。

```
# AP VM の /etc/hosts
10.0.1.20  db.owl.internal
10.0.2.10  registry.owl.internal
```

証明書は CN/SAN を `db.owl.internal` / `registry.owl.internal` で発行する。

### 1-2. 内部 CA 証明書の配置

```sh
install -d -m 755 /etc/owlv

# libpq の verify-full が使う CA(PGSSLROOTCERT で明示指定)
install -m 640 -o _owlbatch -g _owlbatch internal-ca.pem /etc/owlv/db-ca.pem

# OpenBSD ftp(1) の libtls が使う CA をシステム信頼ストアへ
cat internal-ca.pem >> /etc/ssl/cert.pem
```

`/etc/ssl/cert.pem` は base 配布物であり `sysupgrade` で置き換わりうる。この追記は**プロビジョニングスクリプト(GitOps 管理)に含め、アップグレード後に冪等に再適用**されるようにする。手で足したまま放置すると、ある日の更新後に静かにデプロイ fetch が TLS 検証で落ちる。

---

## 2. PG 接続設定 — `.pgpass` を使い、パスワードを crontab に書かない

```
# /var/lib/owlbatch/.pgpass  (mode 600, owner _owlbatch)
# 第1フィールドは PGHOST と完全一致させる(ホスト名運用なのでホスト名)
db.owl.internal:5432:owlv:batch_role:<batch_role_password>
```

パスワードは `.pgpass` が補完し、CA は `PGSSLROOTCERT` で渡す。crontab には接続先・SSL モード・タイムアウトのみを書く。

---

## 3. crontab — `/etc/crontab`(システム crontab)を使う理由

OpenBSD のシステム crontab(`/etc/crontab`)は 6 番目フィールドで実行ユーザーを指定できる。バッチ専用ユーザーを明示でき、監査・レビューが容易。

```
# フォーマット
# min  hour  mday  month  wday  user       command
```

**バックスラッシュ行継続は OpenBSD cron では動作しない。** crontab(5) はコマンドフィールドを改行(または `%`)まで 1 コマンドとして `/bin/sh` に渡す。`\` を書くと継続行が別エントリとして解釈され `bad minute` 等で crontab のインストール自体が失敗する。コマンドは 1 物理行に収める。

---

## 4. 起動ラッパースクリプト

cron 行が長くなる問題と `lockf` の引数組み立てを 1 箇所に集約するため、起動定型専用の薄いラッパーを 1 本置く。「ロジックではなく起動定型」なので §9 の判断基準で sh に残してよい部類。

```sh
#!/bin/sh
# /usr/local/libexec/owlv-run-batch
# 使い方: owlv-run-batch <subcommand> [lockf-timeout-sec]
set -eu
umask 027   # 初回作成されるログを他者から読ませない(以後は newsyslog が 640 で維持)

CMD="${1:?usage: owlv-run-batch <cmd> [timeout]}"
TIMEOUT="${2:-0}"

# 許可リスト — typo でロックファイルやログが意図しない名前で生成されるのを防ぐ
case "$CMD" in
  daily-close|wal-ship|vacuum-check) ;;
  *) echo "owlv-run-batch: unknown command: $CMD" >&2; exit 64 ;;
esac

LOCKFILE="/var/run/owl/${CMD}.lock"
LOGFILE="/var/log/owl/${CMD}.log"

# exec で wrap するので、ロック取得後の終了コードは owlv-batch-center の値が
# そのまま cron へ届く。パイプは一切噛まない(§6 参照)。
exec lockf -t "$TIMEOUT" "$LOCKFILE" \
     /usr/local/bin/owlv-batch-center "$CMD" \
     >> "$LOGFILE" 2>&1
```

```sh
chmod 555 /usr/local/libexec/owlv-run-batch
chown root:bin /usr/local/libexec/owlv-run-batch
```

---

## 5. 完全な `/etc/crontab` 例

```crontab
SHELL=/bin/sh
PATH=/usr/local/bin:/usr/bin:/bin
MAILTO=""

# libpq 接続先(パスワードは /var/lib/owlbatch/.pgpass が担う)
PGHOST=db.owl.internal
PGPORT=5432
PGDATABASE=owlv
PGUSER=batch_role
PGSSLMODE=verify-full
PGSSLROOTCERT=/etc/owlv/db-ca.pem
PGCONNECT_TIMEOUT=10

# 日次決算クローズ  02:00  (spec §4 nine-phase closing pipeline)
# lockf timeout=0: ロック取れなければ即スキップ(前回が長引いている場合)
0  2  *  *  *  _owlbatch  /usr/local/libexec/owlv-run-batch daily-close 0

# WAL アーカイブ転送  15 分ごと
# lockf timeout=60: 前回が走っていても 60 秒だけ待ってから諦める
*/15  *  *  *  *  _owlbatch  /usr/local/libexec/owlv-run-batch wal-ship 60

# バキューム遅延確認  毎時 :30
30  *  *  *  *  _owlbatch  /usr/local/libexec/owlv-run-batch vacuum-check 0
```

`PGCONNECT_TIMEOUT=10` は、DB VM 応答不能時にバッチが無限に張り付くのを防ぐ。これが無いと、ハングしたまま次サイクルが `lockf` で弾かれ続け、処理が静かに止まる。

### `lockf(1)` フラグの選び方

| フラグ | 意味 | 使いどころ |
|---|---|---|
| `-t 0` | ロック取れなければ即リターン(非ブロック) | 前回が長引く可能性がある長時間バッチ |
| `-t N` | 最大 N 秒待ってから諦める | 通常は短いが稀に伸びるジョブ |
| `-s` | ロック失敗時のエラーメッセージを抑制 | 多重起動を「正常スキップ」と扱いたい場合 |

---

## 6. 終了コードと監視の結線

### 終了コード表

`owlv-batch-center` の終了コード(`Batch.Env.errorToCode` 定義):

| コード | 意味 | 通知経路 |
|---|---|---|
| 0 | 成功 | ─ |
| 1 | ドメインエラー | syslog `daemon.err` → 監視アラート |
| 2 | 入力エラー | syslog `daemon.err` → 監視アラート |
| 3 | ストレージエラー | syslog `daemon.err` → 監視アラート |
| 4 | 接続エラー | syslog `daemon.err` → 監視アラート |
| 5 | 未検出 | syslog `daemon.err` → 監視アラート |
| 6 | 楽観ロック競合 | syslog `daemon.warning` → 警告 |
| 99 | 起動失敗(DB 接続失敗など) | syslog `daemon.crit` → 重大アラート |
| lockf 失敗 | **要実測**(下記) | 多重起動スキップ。下記参照 |

**`lockf` 失敗時の終了コードはターゲット OpenBSD で必ず実測すること。** sysexits.h の番号は文脈によりズレる。

```sh
# 実測コマンド
lockf -t 0 /tmp/x.lock sleep 30 &
lockf -t 0 /tmp/x.lock true; echo "lockf失敗コード=$?"
# → この値が 1–6, 99 と被らないことを確認する
```

### 監視は syslog 一本に集約する

`MAILTO=""` かつ出力をファイルへリダイレクトしているため、**cron 自身は失敗を通知しない**。終了コード表の「監視アラート」は、`owlv-batch-center` 側(Haskell)が `exitWith` の直前に syslog へ書くことで初めて機能する。この一点が監視の生命線。

推奨構造:

1. `Batch.Env.runBatch` が `Left appErr` を受けたら、重大度に応じた priority(`daemon.err` / `daemon.warning` / `daemon.crit`)で syslog へ書く
2. `main` で `exitWith (ExitFailure (errorToCode err))`
3. 監視は syslogd 側で `daemon.err` 以上を専用ファイル/パイプアクションに振り分け、それを監視対象にする

syslog 連携は **Haskell 側(`hsyslog` パッケージ)から直接書く**。`owlv-batch-center ... | logger` のパイプ形式は禁止。パイプラインの終了コードは最後のコマンド(`logger`)の値になり、`owlv-batch-center` の失敗が cron から消える。`/bin/sh` に `pipefail` はない。

**多重起動スキップの扱い**: `exec` 形式のラッパーでは lockf 失敗時に `owlv-batch-center` が起動しないため、`daemon.*` には何も出ない（スキップは無害なので既定では沈黙）。スキップを可視化したい場合のみ、ラッパーを以下の capture 形式に差し替える（exit コードは明示的に保持される）。

```sh
# 多重起動スキップを daemon.info で可視化したい場合のラッパー差し替え版
set +e
lockf -t "$TIMEOUT" "$LOCKFILE" \
      /usr/local/bin/owlv-batch-center "$CMD" >> "$LOGFILE" 2>&1
rc=$?
set -e
# LOCKF_BUSY は §6 の実測値に置き換える
if [ "$rc" -eq "$LOCKF_BUSY" ]; then
  logger -t owlv-batch -p daemon.info "skip ${CMD}: already running"
fi
exit "$rc"
```

---

## 7. ログローテーション — `newsyslog.conf`

```
# logfile                          owner:group      mode  count  size(KB)  when    flags
/var/log/owl/daily-close.log      _owlbatch:wheel   640    7      4096    @T0230   CZ
/var/log/owl/wal-ship.log         _owlbatch:wheel   640   14      1024    $W0      CZ
/var/log/owl/vacuum-check.log     _owlbatch:wheel   640   14       512    $D0      CZ
```

| フラグ | 意味 |
|---|---|
| `C` | ログファイルが存在しなければ作成する |
| `Z` | ローテーション後の旧ファイルを gzip 圧縮 |
| `B` | **使わない** — 「バイナリ扱い(区切りメッセージを書くな)」の意味。テキストログに付けるのは誤り |

**時刻の衝突に注意:** `daily-close` は 02:00 起動なので、ローテーションを `@T02` にすると同時刻になり、バッチが `>>` で開いた fd が rename 後の旧ファイルを掴み続ける事故が起きうる。`@T0230`(02:30)にずらして daily-close の終了後にローテートさせる。

---

## 8. バイナリデプロイとアトミック切替

owlv-batch-center は owlv-app / owlv-projector と同じデプロイレールに統一されている: ホストの [owl-control.sh](../infra/host/sbin/owl-control.sh) `cmd_deploy <tag>` が3バイナリを一括で Forgejo (Git VM, `http://<git_vm>:3000/...`) から取得し、AP VM へ `mv` でアトミック切替する。AP VM → Git VM:3000 は [host/conf/pf.conf](../infra/host/conf/pf.conf) の恒久ルール（git_vm は内部固定IPのみが宛先のため、DR射出のような外部宛先と違い時限ピンホール化は不要と判断）。

以前は本セクションで `owlv-deploy-batch`（AP VM 自身が registry.owl.internal から HTTPS+signify 三重検証で取得する、より強固な方式）を想定していたが、**実装されたことは一度もない** —— CI の署名生成パイプライン（`.forgejo/workflows/build.yml` 自体が未整備）が無い状態で検証側だけ作っても検証対象の署名済みアーティファクトが存在せず、機能しない。以下は CI 署名パイプライン整備後に検討する**将来の強化案**として保持する（現状の実装は上記の `owl-control.sh cmd_deploy` の素朴な fetch+mv のみで、signify 検証は無い）。

### 将来案: ビルドサーバ側 — 署名と manifest の生成形式を固定する

```sh
# ビルドサーバで実行
# 1. バイナリ単体の signify 署名
signify -S -s /etc/owlv/signing.sec -m owlv-batch-center -x owlv-batch-center.sig

# 2. SHA256 マニフェスト(バイナリのハッシュ + ビルド時 uname)を生成し署名
#    sha256 -r で "hash  filename" 形式(GNU 互換)になる。既定は "SHA256 (f) = h" で
#    消費側の grep に掛からないため、必ず -r を使う。
sha256 -r owlv-batch-center > SHA256
echo "uname=$(uname -r)" >> SHA256
signify -S -s /etc/owlv/signing.sec -m SHA256 -x SHA256.sig
```

`signing.sec` はビルドサーバ上でパスフレーズ保護し、アクセスを厳格に制限する。AP VM には公開鍵(`signing.pub`)のみを置く。

### 将来案: AP VM 側 — デプロイスクリプト

```sh
#!/bin/sh
# /usr/local/sbin/owlv-deploy-batch — sh に残す最後の砦
# Rev.2 §4.2: signify 署名 + SHA256 + uname の三重検証
# OpenBSD base の ftp(1) を使用(ports 不要)
set -eu
umask 077   # 検証前のステージングバイナリを 600 に保ち、実行・読み取りを封じる

REGISTRY="https://registry.owl.internal/artifacts"
BINARY=/usr/local/bin/owlv-batch-center
STAGING=/usr/local/bin/owlv-batch-center.new
PUBKEY=/etc/owlv/signing.pub

# 異常終了・途中失敗のいずれでも検証前の成果物を残さない
trap 'rm -f "$STAGING" "$STAGING.sig" /tmp/owlv-manifest /tmp/owlv-manifest.sig' EXIT

# 1. ピンホール開放中に HTTPS でバイナリ・署名・マニフェストを取得
#    -V: 進捗表示を抑制(-q は OpenBSD ftp に存在しない)
ftp -V -o "$STAGING"             "$REGISTRY/owlv-batch-center"
ftp -V -o "$STAGING.sig"         "$REGISTRY/owlv-batch-center.sig"
ftp -V -o /tmp/owlv-manifest     "$REGISTRY/SHA256"
ftp -V -o /tmp/owlv-manifest.sig "$REGISTRY/SHA256.sig"

# 2. マニフェスト自体の signify 署名を検証
signify -V -p "$PUBKEY" -m /tmp/owlv-manifest -x /tmp/owlv-manifest.sig

# 3. バイナリの signify 署名を検証
signify -V -p "$PUBKEY" -m "$STAGING" -x "$STAGING.sig"

# 4. SHA256 をマニフェストと照合(sha256 -r 形式: "hash  filename")
EXPECTED=$(grep " owlv-batch-center$" /tmp/owlv-manifest | awk '{print $1}')
ACTUAL=$(sha256 -q "$STAGING")
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "SHA256 mismatch: got $ACTUAL expected $EXPECTED" >&2
  exit 1
fi

# 5. カーネルバージョン照合(マニフェストのサイドカー uname= を使う。
#    バイナリを strings で grep するのは信頼性が低いため行わない)
BUILT_UNAME=$(grep "^uname=" /tmp/owlv-manifest | cut -d= -f2)
RUNNING=$(uname -r)
if [ "$BUILT_UNAME" != "$RUNNING" ]; then
  echo "Kernel mismatch: built=$BUILT_UNAME running=$RUNNING" >&2
  exit 1
fi

# 6. 検証済みバイナリを実行可能化し、アトミック切替
#    (同一 filesystem 上の mv = rename(2) = アトミック。
#     走行中の旧バイナリは inode を保持するため新旧は衝突しない)
chmod 555 "$STAGING"
chown root:bin "$STAGING"
mv "$STAGING" "$BINARY"

echo "Deploy OK: $BINARY  sha256=$ACTUAL  uname=$BUILT_UNAME"
# 後片付けは EXIT trap が行う(STAGING は mv 済みなので rm -f は無害)
```

検証は「マニフェスト署名 → バイナリ署名 → ハッシュ一致 → OS リリース一致」の順で、**どれか一つでも失敗すれば trap が成果物を消して終了**する。検証前のバイナリが PATH 上に実行可能な形で残る瞬間は存在しない。

---

## 9. 設計メモ — sh を追加しない判断基準

以下は sh を書かず、Haskell 側(`Batch.*`)を拡張する:

- 条件分岐(前日の処理が終わっているか確認してから実行する等)
- エラーからのリトライロジック
- 複数バッチの順序制御(daily-close が終わったら wal-ship を走らせる等)
- 環境変数の動的生成
- syslog 書き込み(専用 effect の本番インタープリタを `hsyslog` に差し替える)

以下は sh に残してよい:

- crontab のスケジュール行(OS スケジューラなので置き換えない)
- `owlv-run-batch` ラッパー(`lockf` + ログリダイレクトの起動定型のみ)
- `newsyslog.conf`(ファイルローテーションはシステムに任せる)
- `owl-control.sh cmd_deploy`(バイナリ自身がデプロイできないため、最小限の sh。
  §8 の signify版 `owlv-deploy-batch` を将来実装する場合もここに該当する)

---

## 付録: セットアップ順序チェックリスト

1. `groupadd` / `useradd` / ディレクトリ作成(前提)
2. 内部 PKI 整備(§1)— **これを最初にやらないと §2 が全部落ちる**
3. `.pgpass` 配置・パーミッション 600(§2)
4. `owlv-run-batch` 設置(§4)
5. `lockf` 失敗コードを実測し §6 の表を確定(§6)
6. `/etc/crontab` 投入・1 行検証(§3, §5)
7. `newsyslog.conf` 追記(§7)
8. 初回デプロイ: ホストから `doas owl-control.sh deploy vX.Y.Z`(§8。
   owlv-app/owlv-batch-center/owlv-projector を一括取得)
9. syslogd の `daemon.err` 以上の振り分けと監視結線(§6)
10. 予備機で初回デプロイ → 全バッチの手動実行 → 終了コードと syslog 到達を確認