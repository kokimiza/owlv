# CQRS リードモデル 設計書

## 1. 背景・スコープ

[Shell/EventStore.hs](../src/Shell/EventStore.hs) は PostgreSQL を唯一の真実源（Command側）として実装済み（[doc/tenant_isolation.md](tenant_isolation.md) §4 のストリーム分割・RLSもこの上に成立している）。一方、`brick` TUI の各画面は現状「コマンド実行のたびに対象ストリームをロード→`evolve`で `AppBook` をフォールド」する以外の読み取り経路を持たない。

これは IFRS 会計システムとして2つの限界に当たる:

1. **検索・横断クエリが式に乗らない**: 伝票検索（[Shell/TUI/Screen/VoucherSearch.hs](../src/Shell/TUI/Screen/VoucherSearch.hs)）、期間横断の残高推移、KPI（spec §6）は「現在の `AppBook`」という単一スナップショットの形では表現できない。`AccountCode`/期間/相手先などの軸でのフィルタ・集計が必要で、これは素直にSQLが持つ仕事である。
2. **再フォールドのコストが運用期間に対して線形に増える**: IFRS は複数年の比較財務諸表・ECL再評価・遡及訂正を要求するため、イベント数は事業年数とともに単調増加する。AP VM上で複数の運用者が同時にSSHしてそれぞれ別の `owlv-app` プロセスを起動するたびに全件再フォールドするのは、システムの寿命とともに確実に劣化する設計である。

そのため、**Command側（PostgreSQL、追記専用、`decide`の権威データ）と Query側（SQLite3、AP VM上にin-process、検索・一覧・KPI専用）を分離する**。本書はQuery側プロジェクターの設計を確定する。連結（[tenant_isolation.md](tenant_isolation.md) §4.3）・バッチ処理（[cron_batch.md](cron_batch.md)）と同じく、Tenant隔離の枠内で構造化する。

## 2. 全体アーキテクチャ

```
            ┌─────────────────────── DB VM ───────────────────────┐
            │  PostgreSQL: events / stream_version / tenants ...  │
            │  (tenant_isolation.md §6 の RLS がここで効く)        │
            └───────────────┬───────────────────────┬─────────────┘
                             │ INSERT (CommandExecutor)   │ LISTEN/NOTIFY + SELECT (catch-up)
                             │                             │
              ┌──────────────▼──────────────┐  ┌───────────▼────────────────┐
              │   owlv-app (TUI, 複数プロセス) │ │ owlv-projector (単一プロセス) │
              │   §6.1: decide はここでのみ   │  │   §3: 唯一のSQLite書き込み者   │
              │   実行 (常にPGの権威フォールド) │  │                              │
              └──────────────┬──────────────┘  └───────────┬────────────────┘
                             │ SELECT (検索・一覧画面のみ)        │ INSERT/UPDATE
                             ▼                             ▼
                   ┌───────────────────── AP VM ローカルディスク ─────────────────────┐
                   │  /var/lib/owlv/readmodel/identity.sqlite3   (Identity stream)  │
                   │  /var/lib/owlv/readmodel/<tenant_id>.sqlite3 (Tenant毎)        │
                   └───────────────────────────────────────────────────────────────┘
```

`owlv-app`（TUI）は読み取り専用クライアントとしてのみSQLiteに触れる。書き込み（プロジェクション）を行うのは `owlv-projector` という独立した1プロセスだけであり、これが §3 の「シングルライター」制約の実体である。

## 3. プロジェクタープロセス (`owlv-projector`)

[cron_batch.md](cron_batch.md) の `_owlbatch` と対になる、AP VM上の常駐サービスアカウント `_owlproject`（nologin、doasルール無し=昇格不可）で動作する常駐デーモン。`rcctl` 管理の1サービスとして1本だけ起動し、複数起動を `rc.d` のpidファイルで禁止する。

### 3.1 購読方式 — LISTEN/NOTIFY を主、ポーリングを保険

`Shell.EventStore.appendToPg`（[EventStore.hs:183](../src/Shell/EventStore.hs#L183)）の `events` INSERTと同一トランザクション内で `PG.execute conn "SELECT pg_notify('owlv_events', ?)" (PG.Only notifyPayload)` を追加する（`notifyPayload` は対象が Tenant streamなら `tenant_id`、Identity streamなら固定文字列 `"identity"`）。PostgreSQLのNOTIFYは**コミット後にのみ配送される**ため、ロールバックされた追記が誤って配送されることはない。

`owlv-projector` は起動時に `LISTEN owlv_events` した後、通知を待ち受けつつ最大2秒間隔でも自発的にポーリングする（NOTIFYの取り逃し——プロジェクター再起動中の通知や、ネットワーク断からの復帰直後——に対する保険。[02-wan-network.sh](../infra/host/steps/02-wan-network.sh) のコメントにもある「再現しにくい一度きりの事故への保険」という方針と同じ考え方）。通知が無くても2秒ごとに自分のチェックポイントより新しい `seq` が無いか確認するため、NOTIFYが完全に欠落しても**遅延が最大2秒に留まる**ことが保証される。

### 3.2 チェックポイント管理

チェックポイントは**SQLite側に**持たせる（Postgres側に「誰がどこまで読んだか」の状態を持たない——プロジェクターはPostgresにとって単純な読み取り専用クライアントの1つ）。

```sql
-- 各 <tenant_id>.sqlite3 / identity.sqlite3 の双方に同じ形で持つ
CREATE TABLE IF NOT EXISTS _projector_checkpoint (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  last_seq    INTEGER NOT NULL DEFAULT 0,
  updated_at  TEXT    NOT NULL
);
INSERT OR IGNORE INTO _projector_checkpoint (id, last_seq, updated_at) VALUES (1, 0, datetime('now'));
```

1サイクルの処理:

1. `last_seq` をSQLiteから読む。
2. PostgreSQLから `SELECT seq, payload FROM events WHERE tenant_id = ? AND seq > ? ORDER BY seq ASC LIMIT 500`（Identity streamなら `tenant_id IS NULL`）。`forTenant`/`identityStore`（[tenant_isolation.md](tenant_isolation.md) §5.3）と同じ束縛済みハンドル経由で読む——生の `tenant_id` パラメータをこの層でも作らない。
3. 取得したイベント群をHaskellの `evolve` 相当ではなく、**読みモデル専用の畳み込み関数**（§5.4）でビュー行へ変換し、SQLite側の対象テーブルへ `INSERT ... ON CONFLICT DO UPDATE`。
4. ビュー行の書き込みと `_projector_checkpoint` の更新を**同一SQLiteトランザクション**でコミットする。

### 3.3 冪等性・クラッシュ復旧

ステップ4を同一トランザクションにすることが本設計の要——プロジェクターがバッチ処理中にクラッシュしても、未コミットのバッチは丸ごと消え、再起動後は前回コミット済みの `last_seq` から再開する。ビュー側のテーブルが集約IDを主キーとする上書き（`ON CONFLICT DO UPDATE`）である限り、同じイベントを2回処理しても結果は同じになる（Postgres側の`events`はあくまで追記専用の真実源で、SQLite側の再生は何度繰り返しても安全という設計にする）。これにより2フェーズコミットや外部のメッセージキューは不要。

## 4. マルチテナント分離 — テナントごとに別ファイル

### 4.1 なぜ `tenant_id` 列ではなくファイル分離か

PostgreSQL側はRLS（[tenant_isolation.md](tenant_isolation.md) §6.3）という**DBエンジンレベルのfail-closed機構**を持つが、SQLiteにRLS相当の機能は無い。単一のSQLiteファイルに全テナントの行を `tenant_id` 列付きで詰め込む設計だと、Tenant隔離の最終防衛線が「アプリ側で `WHERE tenant_id = ?` を書き忘れない」という人間の注意力だけになり、tenant_isolation.md §3 が再三否定してきた前提（「クエリを1つ間違えただけでは他社のデータに到達できない構造にする」）に反する。

そのため、**Tenantごとに物理的に別のSQLiteファイル**に分離する。

```
/var/lib/owlv/readmodel/identity.sqlite3       -- Identity stream専用（Userレジストリ等）
/var/lib/owlv/readmodel/<tenant_id>.sqlite3    -- Tenantごとに1ファイル
```

「`WHERE`を書き忘れる」という事故そのものが起こり得ない——間違ったファイルを開かない限り他社のデータは物理的に同じプロセスのアドレス空間にすら載らない。これは[tenant_isolation.md](tenant_isolation.md) §9 が将来のエスカレーションパスとして残した「規制上の理由で物理分離が必要なTenantは別DBに切り出す」を、SQLiteには最初から（コストがほぼゼロなので）適用する判断である。

### 4.2 Haskell型での束縛

`Shell.EventStore.forTenant`（[tenant_isolation.md](tenant_isolation.md) §5.3）と同じ閉じ込めパターンを読み取り側にも適用する。

```haskell
-- Shell/ReadModel.hs (新設)
data ReadModel = ReadModel
  { rmQuery  :: SQL.Query -> [SQL.SQLData] -> IO [SQL.Row]  -- SELECT専用。INSERT/UPDATEを呼べない型にする
  , rmTenant :: Maybe TenantId  -- Nothing = Identity stream
  }

forTenantRead :: TenantId -> IO (Either AppError ReadModel)
identityRead  :: IO (Either AppError ReadModel)
```

`forTenant`（書き込み側）と同様、呼び出し側に生の `TenantId` を渡せるAPIを作らない。TUIの `AppState` がテナント切替時に `EventStore` を再生成するのと同じタイミングで `ReadModel` も再生成し（[tenant_isolation.md](tenant_isolation.md) §5.5 のハンドル再束縛と完全に対をなす）、古いテナントの `ReadModel` ハンドルを使い続けるコードパスを残さない。`rmQuery` の型はSELECT文しか実行できないAPIにし、`owlv-app` プロセスからは構造的に書き込みができないようにする（実際のファイルオープンも `SQLITE_OPEN_READONLY` で行う——OSレベルでも書き込み権限を持たない)。

### 4.3 OpenBSD pledge/unveil との関係・残存リスク

`owlv-app`（TUI）プロセスは `unveil("/var/lib/owlv/readmodel", "r")` を起動時に一度だけ実行し、以後はディレクトリ全体への読み取りのみを許可する。`pledge` には `rpath`（ファイル読み取り）と既存のPostgreSQL接続用の `inet`/`dns` を含める。`owlv-projector` プロセスは逆に `unveil("/var/lib/owlv/readmodel", "rwc")` のみで、`owlv-app` 側が持つ他の特権（doas経由のOSアカウント同期等、[vm-ap/setup.sh](../infra/vm-ap/setup.sh)）は一切与えない——プロジェクターが乗っ取られても、できることはSQLiteファイル群の改竄のみに限定され、これは§3.3の通り破棄して再構築可能な被害に留まる。

**残存リスクとして明記する**: OpenBSDの `unveil` はプロセス生存期間中、許可を「追加」する方向にしか動かせず、一度見せたパスを後から隠すことはできない。`unveil` を §4.1のディレクトリ単位（`readmodel/` 全体）で一度だけ行う設計のため、テナントAの画面からテナントBへ切り替えた後も、OSレベルでは依然テナントAのファイルを開く能力がプロセスに残ったままになる——`unveil` は「このプロセスは無関係な任意ファイルに触れない」という外側の防御線であり、「いま開いているテナントを越えて読めない」という内側の防御線（§4.2のHaskell型束縛）の代替にはならない。これは[tenant_isolation.md](tenant_isolation.md) §3 の3層防御と同じ考え方——どの層も単体では十分でなく、Haskell型の閉じ込め（§4.2）が実質的な境界であり、`unveil`/`pledge` はその外側にもう一枚加えるだけの多重防御である。

## 5. SQLite物理設計

### 5.1 WALモード・PRAGMA設定

`owlv-projector`・`owlv-app` 双方が接続時に必ず設定する:

```sql
PRAGMA journal_mode = WAL;       -- 単一ライター・複数リーダーを完全並列化する前提 (§3)
PRAGMA synchronous  = NORMAL;    -- WAL下では安全な設定（FULLはWALでは過剰）
PRAGMA busy_timeout = 5000;      -- リーダーが書き込み直後の短いロック窓に当たった場合の待機
PRAGMA foreign_keys = ON;
```

`journal_mode=WAL` はファイル単位の設定としてディスクに永続化されるため、ファイル新規作成時（§7のリビルド時含む）に必ず一度実行する。

### 5.2 テーブル設計方針 — JSON1 + `GENERATED ALWAYS AS` 仮想カラム

[Core.Event](../src/Core/Event.hs) のイベントは既に `aeson` で `ToJSON`/`FromJSON` が実装済みであるため、プロジェクション結果を**フラットなドメインオブジェクトのJSONとしてそのまま1カラムへ保存**し、検索キーにしたい属性だけを `GENERATED ALWAYS AS (json_extract(...)) VIRTUAL` で仮想カラム化してインデックスを貼る。スキーマ変更（新しい検索軸の追加）は新しい仮想カラム+インデックスの追加だけで済み、JSON本体のマイグレーションが要らない。

```sql
CREATE TABLE view_journal_entry (
  entry_id    TEXT PRIMARY KEY,            -- JournalEntryId (UUID, 非JSON実カラム)
  payload     TEXT NOT NULL,               -- JournalEntry の aeson JSON
  voucher_date TEXT GENERATED ALWAYS AS (json_extract(payload, '$.voucherDate')) VIRTUAL,
  action_type  TEXT GENERATED ALWAYS AS (json_extract(payload, '$.actionType')) VIRTUAL,
  account_code TEXT GENERATED ALWAYS AS (json_extract(payload, '$.lines[0].accountCode')) VIRTUAL
);
CREATE INDEX idx_voucher_date  ON view_journal_entry(voucher_date);
CREATE INDEX idx_action_type   ON view_journal_entry(action_type);
```

### 5.3 Money/`Decimal` を仮想カラム化する際の罠

[Core.Domain.Money](../src/Core/Domain/Money.hs) は `Money` を `show` した**10進数の文字列**（例 `"1000.00"`）としてJSONへシリアライズする（CLAUDE.mdの「Double禁止」を満たすための設計）。これは2つの意味で罠になりやすい:

1. `json_extract` で取り出した値はJSON文字列のままなのでSQLite側は自動的に数値化しない（floatに化けるわけではない）——ここは安全。
2. ただし**そのままでは数値としてのソート・範囲検索ができない**。文字列としての辞書順ソートは負号・桁数が揃わない限り正しい数値順にならない（`"-50.00" > "100.00"` と判定されてしまう）。SQL側で `CAST(... AS REAL)` して回避するのは**CLAUDE.mdが禁じているDoubleを読み取り経路に持ち込むのと同義**であり、やってはならない。

金額の数値比較・合計・範囲フィルタが必要なビュー（残高、KPI集計）には、**Haskell側のプロジェクター（SQLでのCAST/json_extractではなく、`evolve`相当のHaskellコードそのもの）が `Money` を最小貨幣単位の `INTEGER`（例: セント/銭単位）へ変換し、実カラムとして書き込む**。仮想カラムにはしない——SQLite側の式で再現するのではなく、Haskell側で1回だけ正しく変換した値をそのまま列として保存する。

```sql
CREATE TABLE view_account_balance (
  account_code   TEXT NOT NULL,
  period         TEXT NOT NULL,             -- "YYYY-MM"
  payload        TEXT NOT NULL,             -- Money の JSON (表示用、表示精度を保持)
  balance_minor  INTEGER NOT NULL,          -- Haskell側で算出した最小単位の整数（ソート・集計専用）
  PRIMARY KEY (account_code, period)
);
CREATE INDEX idx_balance_minor ON view_account_balance(balance_minor);
```

表示には常に `payload`（`Decimal` 由来の正確な文字列）を使い、`balance_minor` はソート・閾値判定（spec §3 のマテリアリティ判定等）にのみ使う。2カラムの食い違いが起きないよう、両方を**同じプロジェクター関数の同じ入力**から1回で生成する。

### 5.4 主要ビュー一覧（初期セット）

| ビュー | 起源イベント | 用途 |
|---|---|---|
| `view_journal_entry` | `JournalEntryRecorded` | 伝票検索 ([VoucherSearch.hs](../src/Shell/TUI/Screen/VoucherSearch.hs)) |
| `view_account_balance` | `JournalEntryRecorded`（debit/credit積算） | 残高表示・マテリアリティ判定 (spec §3) |
| `view_fixed_asset` | `FixedAssetRegistered`/`DepreciationRecorded`/`ImpairmentRecognized`/... | 固定資産台帳一覧 (spec §2.4) |
| `view_ecl` | `EclMeasurementRecorded` | ECLステージ別一覧 (spec §4.7.5–10) |
| `view_judgment_log` | `JudgmentLogRecorded` | 判断ログ検索 (spec §5) |
| `view_kpi_daily` | 上記複数イベントの集計 | 経営指標ダッシュボード (spec §6) |

各ビューは「主キー = 集約ID（+ 必要なら期間）」「`ON CONFLICT DO UPDATE`」で冪等に保つ。`view_kpi_daily` のような集計ビューは個々のイベントから増分更新するのではなく、**そのチェックポイント区間で影響を受けた集約IDの行だけ`view_account_balance`等から再集計**する（増分の差分管理は誤差が蓄積しやすく、IFRSの数値が「再計算すれば必ず合う」ことを優先する）。

## 6. 一貫性モデルと読み取りパスの使い分け

### 6.1 `decide` は常にPostgreSQLの権威フォールドを使う

SQLiteのリードモデルは**いかなる理由でも `Core.Decide.decide` の入力に使わない**。[CommandExecutor.hs](../src/Shell/CommandExecutor.hs) の「load events → fold `evolve` → `decide` → append events」は本書導入後も変更しない（CLAUDE.mdの「Shellは既定では変更しない」方針、[tenant_isolation.md](tenant_isolation.md) §5.4 と同じ理由）。SQLiteは**表示・検索専用の写し**であり、書き込みの正しさの根拠には絶対に使わない——プロジェクターの遅延・障害が会計の正しさに影響しないことを構造的に保証する一点。

### 6.2 「自分が書いた直後」の画面は再フォールドの結果をそのまま使う

伝票登録直後にその伝票を一覧に出す、といった**読み取り直後の自分自身の書き込み**を表示する画面は、§6.1で`CommandExecutor`がすでに計算済みの最新 `AppBook`（メモリ上の値）からそのまま描画する。プロジェクターのLISTEN/NOTIFYは§3.1の通り通常1秒未満で追従するが、同一トランザクション内の自分の書き込みをSQLite経由で待つ設計にはしない——TUIがフリーズしたように見えるブロッキングを避け、また結果的に表示一貫性のための同期機構（poll-until-checkpoint等）を導入する必要も無くなる。

### 6.3 それ以外の画面はSQLiteから読む

伝票検索・残高一覧・KPIダッシュボードなど、**自分が今この場で書いたわけではないデータを表示する画面**はすべてSQLite経由（§4.2の `ReadModel` ハンドル）で読む。他の運用者・`owlv-batch-center`（[cron_batch.md](cron_batch.md)）が書いたイベントも、プロジェクターを介して同じ経路で反映される。多くても数秒の遅延があり得ることを前提にした設計であり、IFRSの確定的な数値（決算書そのもの）は別途、決算時にPostgreSQLの権威フォールドから直接生成する経路（spec §1.2 の九段階クロージングパイプライン）を持つ——SQLiteのビューはあくまで日常的な参照・検索の高速化用途に限定する。

## 7. 運用 — リビルドとスキーマ変更

SQLiteのリードモデルファイルは**使い捨て可能なキャッシュ**である。`owlv-projector --rebuild <tenant_id|identity|all>` を用意し、対象ファイルを削除→新規作成→`_projector_checkpoint.last_seq = 0` から全件再生する。新しいビュー（新しい検索軸）を追加するときは、マイグレーションフレームワークを導入せず、単純に対象ファイルを再構築する運用とする（[tenant_isolation.md](tenant_isolation.md) §7 の移行手順がPostgres側の追記専用原則を守るのとは対照的に、SQLite側はそもそも真実源ではないため「作り直して問題ない」という前提に立てる）。

新規Tenant作成（`TenantCreated`、[tenant_isolation.md](tenant_isolation.md) §4）時には、プロジェクターが該当 `<tenant_id>.sqlite3` を初回検出時に自動作成する（事前のディレクトリ走査やテナント一覧の同期処理を別途持たない——`listActiveTenantIds` で能動的に把握するのは [cron_batch.md](cron_batch.md) のバッチループと同じパターンを流用してよい）。

## 8. 既存ドキュメントとの関係整理

- **[tenant_isolation.md](tenant_isolation.md)**: PostgreSQL側の3層防御（§3）の上に成立する。SQLite側はRLSを持てないため、同等の structural defense をファイル分離（§4.1）とHaskell型束縛（§4.2）で再現する。Identity stream/Tenant streamの分割は `identity.sqlite3`/`<tenant_id>.sqlite3` という1対1の対応物を持つ。
- **[cron_batch.md](cron_batch.md)**: `owlv-batch-center`（`_owlbatch`）はTenantごとに `forTenant` でループする書き込み専用バッチであり、SQLiteには一切触れない。`owlv-projector`（`_owlproject`）はその逆——PostgreSQLには読み取り専用（`SELECT`のみ、`BYPASSRLS`は持たず §6.6 と同じく `forTenant`/`identityStore` 経由でテナントごとに正規の権限で読む）で、SQLiteへの書き込み専用。両者は権限・役割ともに重ならない別プロセス。
- **CLAUDE.md**: 「Event store: PostgreSQL。Read model: SQLite3」の記述（本書策定により確定）と、「`src/Shell/` のみがIOを許可される」という制約は変わらない——`owlv-projector` も `Shell.ReadModel`/`Shell.Projector`（新設、`Core/` には置かない）の薄いIOラッパーとして実装する。

## 9. テスト戦略

- **プロパティテスト**: 同じイベント列を2回（チェックポイントを意図的に巻き戻して）プロジェクションした結果が1回適用した場合と一致すること（§3.3の冪等性の直接検証）。
- **クラッシュ復旧テスト**: バッチ処理中（チェックポイント更新前）にプロセスをkillし、再起動後に取りこぼし・重複が無いことを確認する。
- **テナント漏洩テスト**: テナントAの `ReadModel` ハンドルで `rmQuery` を呼んでも、ファイルが物理的に分離されているためテナントBの行が**型レベルでもファイルレベルでも**返らないことを確認する（tenant_isolation.md §8 のPostgres側RLSテストと対をなす、SQLite側の検証）。
- **Money往復テスト**: `view_account_balance` の `balance_minor` から復元した値と `payload` の `Decimal` 文字列を独立に計算し、両者が一致すること（§5.3の二重管理がズレないことの検証）。

## 10. 残課題

- **`owlv-projector` の冗長化**: 現状は単一プロセス・単一障害点。AP VMが1台構成である現行アーキテクチャ（[hypervisor_rationale.md](hypervisor_rationale.md)）の制約内では、プロジェクター停止時もPostgreSQL側の書き込み・`decide`は影響を受けず、SQLiteの遅延が増えるだけ（§6.1の構造的保証）なので、可用性要件が変わらない限り先送りで問題ない。
- **KPIビュー（`view_kpi_daily`）の具体的な集計ロジック**: 本書はビューの位置づけ（§5.4・§6.3）のみを確定し、spec §6 の指標定義そのものは別ドキュメント／実装時に詳細化する。
