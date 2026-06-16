# イベントストア テーブル定義書

owlv のイベントストアは PostgreSQL 18 単一スキーマで構成する。
本書は [Shell/EventStore.hs](../../../src/Shell/EventStore.hs) の `migrate` 関数に埋め込まれていた
DDL を正式なテーブル定義書として切り出し、PostgreSQL 18 の機能を前提に再設計したもの。
コード側の `migrate` はこの定義書と同期させること（定義書を更新したら `migrate` も追従する）。

対象 DB: `owl`（[infra/vm-db/setup.sh](../setup.sh) が作成）
適用ユーザー: `owl_app`（RLS 前提、[pg_hba.conf](../pg_hba.conf) で `hostssl` 必須）

## 設計方針

- **追記専用**: `events` は UPDATE / DELETE を行わない。訂正は新規イベントの追記で表現する（CLAUDE.md「イベントストアは追記専用」）。
- **payload は JSONB**: 旧実装は `payload TEXT` に JSON 文字列を素通しで詰めていた。検索・整合性チェックを SQL 側でも行えるよう `JSONB` に変更する。
- **IDENTITY 列**: `BIGSERIAL` は内部的に `SERIAL` 同様シーケンス権限が独立せず管理しにくいため、SQL 標準の `GENERATED ALWAYS AS IDENTITY` に置き換える（PG10+ の推奨）。
- **UUIDv7 をイベント ID に採用**: PostgreSQL 18 で `uuidv7()` が組み込み関数として追加された（pgcrypto 等の拡張不要）。時系列ソート可能な UUID をイベント単位の外部参照キーとして持たせ、将来の複数ストリーム化・外部システム連携（DR 含む §2.2）に備える。`seq` は楽観ロック用の内部順序、`event_id` は外部に渡す不変識別子という役割分担にする。
- **生成列で type を取り出す**: PostgreSQL 18 は `STORED` に加え `VIRTUAL` 生成列をサポートする。`event_type` を payload から都度導出する代わりにアプリ側で明示挿入する方針は変えないが、整合性検証用に `payload_type` を `VIRTUAL` 生成列として持ち、`event_type` とのズレを検出可能にする。
- **改ざん検知用ハッシュ**: spec §7（ハッシュベースの改ざん検知）に対応し、`prev_hash` / `row_hash` を持つ。`row_hash` は `event_type || payload || recorded_at || prev_hash` から計算し、チェーン化する。
- **複数列インデックスは skip scan 前提で設計**: PostgreSQL 18 の B-tree skip scan により、先頭列を絞らない `(event_type, seq)` のような複合インデックスでも `event_type` 単体の絞り込みが効率化される。

## テーブル一覧

| テーブル | 役割 |
|---|---|
| `events` | 追記専用イベントログ本体 |
| `stream_version` | 楽観的並行性制御用のバージョンカウンタ |

---

## `events`

```sql
CREATE TABLE IF NOT EXISTS events (
    seq          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id     UUID        NOT NULL DEFAULT uuidv7(),
    event_type   TEXT        NOT NULL,
    payload      JSONB       NOT NULL,
    payload_type TEXT GENERATED ALWAYS AS (payload ->> 'type') VIRTUAL,
    prev_hash    BYTEA,
    row_hash     BYTEA       NOT NULL,
    recorded_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),

    CONSTRAINT events_type_matches_payload
        CHECK (payload_type IS NULL OR payload_type = event_type)
);

CREATE UNIQUE INDEX IF NOT EXISTS events_event_id_key ON events (event_id);
CREATE INDEX IF NOT EXISTS events_event_type_seq_idx ON events (event_type, seq);
CREATE INDEX IF NOT EXISTS events_recorded_at_idx ON events (recorded_at);
```

| 列 | 型 | 制約 | 説明 |
|---|---|---|---|
| `seq` | `BIGINT IDENTITY` | PK | 追記順を保証する内部シーケンス。楽観ロックの比較値。 |
| `event_id` | `UUID` | NOT NULL, UNIQUE, default `uuidv7()` | 外部公開用の不変イベント識別子。UUIDv7 のため生成順とソート順が一致する。 |
| `event_type` | `TEXT` | NOT NULL | `Core.Event` の代数的データ型コンストラクタ名。 |
| `payload` | `JSONB` | NOT NULL | `Aeson.encode` した `Event` 全体。 |
| `payload_type` | `TEXT` (VIRTUAL GENERATED) | — | `payload->>'type'` を都度算出。`event_type` との不一致を CHECK で検出。 |
| `prev_hash` | `BYTEA` | NULL 可（先頭行のみ NULL） | 直前の行の `row_hash`。チェーン検証用。 |
| `row_hash` | `BYTEA` | NOT NULL | `sha256(event_type \|\| payload::text \|\| recorded_at \|\| coalesce(prev_hash, ''))`。アプリ側で計算して挿入する（spec §7）。 |
| `recorded_at` | `TIMESTAMPTZ` | NOT NULL, default `clock_timestamp()` | 記録時刻。`now()` はトランザクション開始時刻で固定されるため、追記順との対応がより厳密な `clock_timestamp()` を使う。 |

### なぜ `now()` ではなく `clock_timestamp()` か

`now()`（= `transaction_timestamp()`）は同一トランザクション内で固定値になる。`appendToPg` は 1 トランザクションで複数イベントを挿入するため、`now()` のままだと同一トランザクションで追記した複数行の `recorded_at` がすべて同一になり、`seq` 順との時系列対応が失われる。`clock_timestamp()` は呼び出し都度の実時刻を返すため、行ごとに異なる値になる。

---

## `stream_version`

```sql
CREATE TABLE IF NOT EXISTS stream_version (
    id      INT    PRIMARY KEY,
    version BIGINT NOT NULL DEFAULT 0,

    CONSTRAINT stream_version_singleton CHECK (id = 1)
);

INSERT INTO stream_version (id, version)
SELECT 1, COUNT(*) FROM events
ON CONFLICT (id) DO NOTHING;
```

| 列 | 型 | 制約 | 説明 |
|---|---|---|---|
| `id` | `INT` | PK, `CHECK (id = 1)` | シングルトン行であることを制約で明示（旧定義はコメントのみで担保していた）。 |
| `version` | `BIGINT` | NOT NULL, default 0 | 追記済みイベント総数。`esAppend` が `SELECT ... FOR UPDATE` で行ロックし、楽観ロックの比較・更新を行う。 |

現状は単一ストリーム（アプリ全体で 1 系列）を前提にしている。複数アグリゲートに分割する場合は `stream_version` を `(stream_id, version)` の複合 PK に拡張し、`events` に `stream_id UUID` 列を追加する形で拡張できる。今の規模ではオーバーエンジニアリングのため見送り、ここに拡張ポイントとして記録するのみにする。

---

## マイグレーション運用

- スキーマ変更は `Shell.EventStore.migrate` に `CREATE TABLE IF NOT EXISTS` / `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` で追記する。既存の `events` テーブルがある環境に対しては、本書の DDL とは別に移行用の `ALTER TABLE` 文を都度 `migrate` に追加すること（追記専用の原則上、テーブルの再作成は行わない）。
- `row_hash` / `prev_hash` の導入は既存データへの遡及計算が必要になるため、Haskell 側に移行スクリプトを用意してから `NOT NULL` 制約を追加する2段階移行とする。
