# owlv

IFRS（国際財務報告基準）に準拠した個人向け会計 TUI。Haskell + [brick](https://github.com/jtdaugherty/brick) で実装し、Event Sourcing + CQRS をアーキテクチャの骨格に採用している。

```
cabal run owlv
```

## これは何か、何ではないか

「個人の財務記録を、複式簿記とIFRSの認識・測定規則に従って正しく残す」ことが目的のソフトウェアであり、一般的な家計簿アプリではない。仕訳は事後の編集・削除を許さず、訂正は常に元の記録を参照する新規エントリとして積み重なる。記帳のたびに貸借が一致しているかをドメイン層が検証し、原始記録（仕訳帳）から導出される帳簿価額・期末残高・ECL（予想信用損失）などはすべて「正しい入力からの再計算結果」として扱われる。

## アーキテクチャの実態

### イベントストア＝PostgreSQL の追記専用ログ

PostgreSQL 側の真実源は `events`（追記専用）で、`tenant_id` によって **Tenant stream** と **Identity stream** を区別する（[src/Shell/EventStore.hs](src/Shell/EventStore.hs)、[infra/vm-db/schema.sql](infra/vm-db/schema.sql)）。`stream_version` は Tenant ごとの楽観ロック用カウンタ、`identity_stream_version` は User レジストリ等の Identity stream 用カウンタ、`tenants` は Tenant 一覧用のレジストリである。

コマンド実行は「対象 Tenant のイベント + Identity stream をロード → `evolve` で `AppBook` に畳み込み → `decide` → 楽観ロック付きで追記」という sandwich pattern（[src/Shell/CommandExecutor.hs](src/Shell/CommandExecutor.hs)）。PostgreSQL Row Level Security と `forTenant` によるハンドル束縛で、Tenant ごとの読み書きを分離している。

現状、**スナップショットや集約単位のストリーム分割は存在しない**。書き込み判断に使う `AppBook` はコマンド実行時に権威イベントから再構築する。一方、検索・一覧用途には SQLite の CQRS リードモデルがあり、`owlv-projector` が PostgreSQL から転写する。

### 読みモデルの中身（`Core/State.hs`）

`AppBook` は Tenant の現在状態と複数の小さな読みモデルの集合体で、それぞれが特定の会計・運用領域に対応する：

| 読みモデル | 対応領域 |
|---|---|
| `appTenant` | Tenant 自身の状態（作成・停止・廃止） |
| `JournalBook` | 仕訳帳（原始記録） |
| `MasterBook` | 組織・取引先・科目・補助科目・権限スコープ |
| `CashBook` | 入出金・消込・未消込残高 |
| `PeriodsBook` | 会計期間の開閉状態 |
| `AssetBook` | 固定資産台帳（償却・減損・再評価・除却） |
| `EclBook` | 期待信用損失（ECL）測定 |
| `FxBook` | 為替レート |
| `JudgmentLogBook` | 経営判断ログ（spec §5） |
| `BenefitBook` | 従業員給付負債（IAS 19） |
| `TaxBook` | 法人所得税（IAS 12） |
| `UserBook` | ユーザー・ロール・OS 同期状態 |

### FCIS のレイヤー

```
Core/      純粋関数のみ。IO・brick・DB・時刻・乱数の import 禁止。
Shell/     唯一の IO 許可域。PostgreSQL イベントストア・SQLite リードモデル・effectful インタープリタ・TUI。
           ユースケース相当の処理（データ取得 → Core 呼び出し → 永続化）もここに置く。
app/       設定・配線・起動のみ。
projector/ CQRS リードモデル転写デーモンの配線のみ。
batch/     バッチ CLI の配線のみ。
```

FCIS は「純粋か副作用ありか」という1本の境界線でレイヤーを分けるため、Clean Architecture のような独立した UseCases フォルダ（インタラクター層）は作らない。依存方向は `Core ← Shell` の一方向で固定。詳しい追加手順は [CLAUDE.md](CLAUDE.md) の「Recipe for adding a feature」を参照。

## 機能の実装状況（2026年6月時点）

「何が動いていて、何がまだ骨組みだけか」は `doc/` 配下のどのドキュメントにも書かれていないため、ここに明記する。

- **対話的な記帳・マスタ管理（TUI）**：実装済み。[src/Shell/TUI/Screen/](src/Shell/TUI/Screen/) 配下に仕訳入力・マスタ管理（組織／取引先／科目／補助科目／ユーザー）・伝票検索の画面がある。
- **ドメインロジック（`decide`/`evolve`）**：仕訳・固定資産（償却・減損・戻入・再評価・除却）・ECL・FXレート・判断ログ・従業員給付・法人税・Tenant・User まで `Core.Command` に定義済みで、対応する unit/property test が [test/Core/](test/Core/) にある。
- **CQRS リードモデル**：`owlv-projector` が実装済み。PostgreSQL の `LISTEN/NOTIFY` と最大2秒ポーリングで差分を取り込み、SQLite の `view_journal_entry` / `view_account_balance` を更新する。固定資産・ECL・判断ログ・KPI ビューは今後追加。
- **マルチテナント/ユーザー管理**：Tenant stream / Identity stream、RLS、OS ログイン名の User 射影照合、`owl-user-sync` 経由の OS 同期オーケストレーションが実装済み。Tenant 切替 UI やユーザー同期検証バッチは今後の拡張。
- **九フェーズ月次クローズ・バッチ（spec §1.2 / §4）**：`owlv-batch-center daily-close` というCLIの形は存在するが、[batch/Batch/DailyClose.hs](batch/Batch/DailyClose.hs) の実体は `pure ExitSuccess` のみで未実装（`TODO` コメントが残っている）。`wal-ship`・`vacuum-check` も同様にスタブ。
- **本番運用基盤（OpenBSD VM・エアギャップDR・Yubikey認証等）**：[doc/dev_sec_ops.md](doc/dev_sec_ops.md) に設計として詳述されており、`infra/` 配下にそれに対応するプロビジョニングスクリプト・設定ファイル一式（`pf.conf`、`vmd.conf`、各 VM の `setup.sh` など）が存在する。これは設計と一致した実体のあるコードであり、アプリケーション本体とは独立した運用面のレイヤー。

## 開発環境

本番は OpenBSD VM + PostgreSQL（RLS有効）だが、開発時は Docker Compose で素の PostgreSQL を使う。

```bash
docker compose up -d db          # PostgreSQL コンテナ起動（pg_isready 待ち）
docker compose build app         # ソース変更後は明示的に再ビルド
docker compose run --rm app      # TUI を起動して動作確認
```

接続先は Docker ネットワーク内のサービス名 `db`（`PGHOST=db` 等、`docker-compose.yml` に宣言済み）。開発用パスワードのみリポジトリに平文で置いてよい。

ローカルで Haskell ツールチェーンを直接使う場合：

```bash
cabal build
cabal test --test-options='-p "<pattern>"'   # 単体テストはこちらを優先
cabal test                                     # フルスイートはコミット前のみ
fourmolu -i $(git ls-files '*.hs')
hlint app src test
```

`Core/` のテストはインフラ不要で CI 実行対象。`Shell/` の動作確認（PostgreSQL 永続化・TUI 描画）は手動確認のみで、cabal のテストスイートには含めない方針（[CLAUDE.md](CLAUDE.md) 参照）。

## ディレクトリ構成

```
app/        実行バイナリ owlv のエントリポイント（配線のみ）
batch/      バッチ実行バイナリ owlv-batch-center（daily-close / wal-ship / vacuum-check）
projector/  リードモデル転写バイナリ owlv-projector（run / rebuild）
src/Core/   純粋ドメインロジック（コマンド・イベント・decide・evolve・読みモデル）
src/Shell/  PostgreSQL イベントストア・SQLite リードモデル・effectful インタープリタ・brick TUI・ユースケース相当の orchestration
test/Core/  ドメインロジックの property test / unit test
infra/      本番運用基盤（OpenBSD VM・プロビジョニング・DR）のコード化された構成
doc/        会計仕様（ifrs_standard.md）・運用定義書（dev_sec_ops.md）・各種仕様書
```
