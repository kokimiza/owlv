# Audit VM フォレンジックエンジン（fohlen）要件定義書

## 0. この文書の位置づけ

[dev_sec_ops.md §6](dev_sec_ops.md) は Audit VM を「syslog 集約・改ざん検知・外部通報」の基盤として定義し、[infra/vm-audit/setup.sh](../infra/vm-audit/setup.sh) でその受信・封印・cron 検知（`owl-audit-detect.sh`）まで実装済みである。しかし現状の Audit VM は **OpenBSD 標準機能（syslogd・newsyslog・cron + シェルスクリプト）が `/var/log/audit/` にログを溜め込むだけの倉庫室** であり、次の2点を欠く。

1. **全文検索**: 蓄積された `remote.log` および封印済み `.gz` 世代を横断して、任意の文字列・時間範囲で検索する手段がない。
2. **逸脱検知の質**: `owl-audit-detect.sh`（§6.2 実装）は固定閾値の `grep` カウントのみであり、統計的根拠を持たない。

本書はこの2点を解決する常駐サービス **`fohlen`**（[infra/vm-audit/fohlen/](../infra/vm-audit/fohlen/)、Go 製・単一静的バイナリ）の要件を定義する。

### 0.1 採用しないものとその理由

| 候補 | 不採用の理由 |
|---|---|
| Vector + ClickHouse | 一般的な構成だが、OpenBSD 上に Rust/C++ ツールチェーンと列指向DBの運用知識を新たに持ち込む。[hypervisor_rationale.md §2.2](hypervisor_rationale.md) が確定した「運用者の注意力を1点に集中投資する」方針（OpenBSD 標準ツール一本化）に反する。 |
| 機械学習モデルによる異常検知 | [owl-config.toml](../infra/owl-config.toml) の `[vm.audit]` は `memory = "256M"`（§6「ログ集約のみのため軽量」の設計意図どおり最小構成）。推論ランタイム・特徴量ストア・モデル更新パイプラインを載せる余地がなく、ホスト全体が単一物理機（[hypervisor_rationale.md §1.5](hypervisor_rationale.md)）である本システムでは GPU 推論への拡張も見直し条件に挙げているのみで現状は対象外。よって **統計解析（古典的・解析的に検証可能な手法）のみ**を逸脱検知の手段とする。 |
| Elasticsearch / Lucene 系全文検索 | JVM 常駐だけで 256MB を圧迫する。 |
| htmx を CDN から読み込む構成 | audit_lan は外向き通信が `<audit_notify_dst>` ホワイトリスト（443のみ、webhook 通知先限定）に固定されており（[dev_sec_ops.md §6.1 鉄則③](dev_sec_ops.md)）、一般的な CDN 取得経路は構造的に存在しない。htmx 本体はバイナリへ `go:embed` し、実行時のネットワーク取得を一切行わない。 |

### 0.2 「ログ管理システム」と「監査エンジン」の違い

全文検索（§4.3）と統計エンジン（§4.4）を生の syslog 文字列・構文的キー（`source_host`/`facility`/`tag` の組）に対して直接動かすだけでは、`grep` と `awk` をプロセス常駐化しただけの**ログ管理システム**にしかならない。これは owlv 本体が `Core.Event`（型付きイベント）を介さずに生の取引文字列を直接 `decide` に渡すことを禁じている（[CLAUDE.md](../CLAUDE.md) の Recipe、[ifrs_standard.md](ifrs_standard.md) の認識・測定規則）のと対称的な不足である。

そこで fohlen は、生ログ行をいきなり索引・統計の対象にするのではなく、**まず「これは何が起きたイベントか」を分類する正規化層（§4.1）を挟む**。検索・統計・UI はこの正規化済みイベント（`AuditEvent`）を主たる入力とし、生文字列はその補助（全文検索のフォールバック対象、分類できなかった行の取りこぼし防止）として扱う。これにより、たとえば「sudo失敗が3回連続」という構文的カウントではなく「`PrivilegeEscalationAttempt` という意味カテゴリの事象率が普段と異なる」という**意味のある単位**で統計を取れるようになる。これが「ログ管理」から「イベントを理解する監査エンジン」への一段の抽象化である。

---

## 1. 制約条件（設計の出発点）

| 制約 | 出典 | 設計への影響 |
|---|---|---|
| VM メモリ 256MB | `owl-config.toml` `[vm.audit]` | ログ全件をメモリに展開しない。ストリーミング統計（§4.3）・ディスク上の索引（§4.2）を必須とする。 |
| OpenBSD ネイティブ、Go ツールチェーンは Build VM の `ports` 経由 | [dev_sec_ops.md §3.1](dev_sec_ops.md)（GHC と同じロックステップ運用方針を Go にも適用） | `fohlen` は Build VM 上でクロスビルドせず、Build VM 自身にネイティブ `lang/go` を追加してビルドする。AP VM 同様、Build VM と Audit VM は同一 OpenBSD リリースでロックステップ運用する。 |
| audit_lan は他segmentへ双方向遮断（鉄則①） | [dev_sec_ops.md §6.1](dev_sec_ops.md) | `fohlen` はいかなる宛先へも能動的に接続しない（webhook 通知のみ例外、既存 `owl-audit-detect.sh` と同じ送信先ホワイトリスト経由）。UI はホスト発の接続のみを受け付ける受動的リスナーとして実装する（§6）。 |
| ドメインデータ排除（鉄則②） | [dev_sec_ops.md §6.1](dev_sec_ops.md) | 転送されてくる `auth.*` ログにはもともと仕訳金額等のドメインデータが乗らない。`fohlen` 側でも検索対象・索引はこのメタログのみに限定し、将来 owlv アプリ側のログファシリティが誤って転送対象に混入しないことを前提から外さない（混入検知は本書の範囲外、syslog.conf 側の責務）。 |
| 確定済みログは `sappnd` で封印（§6.3） | [dev_sec_ops.md §6.3](dev_sec_ops.md) | `fohlen` は `/var/log/audit/` に対して**読み取り専用**。索引・状態ファイルは別ディレクトリ（§7）に持ち、封印済みログへの書き込みを一切行わない。 |
| 単一プロセス内検知（§6.2） | [dev_sec_ops.md §6.2](dev_sec_ops.md)「検知から通報までを単一プロセス内で完結させ、外部キューや中間サーバーを経由しない」 | `fohlen` が新たに行う統計的検知も、検知〜webhook 送信まで自プロセス内で完結させる。既存 `owl-audit-detect.sh`（cron、閾値ベース）とは独立した別チャンネルとして併存させる（§5）。 |

---

## 2. スコープ

### 2.1 やること

- `/var/log/audit/remote.log`（稼働中）および封印済み `remote.log.*.gz`（過去30世代、[setup.sh](../infra/vm-audit/setup.sh) の `newsyslog.conf` 設定に対応）を対象にした **全文検索**（§4.2）。
- syslog 由来の各種カウンタ（認証失敗率、SSHログイン成功頻度、送信元ホスト別の事象率など）に対する **古典統計に基づく逸脱検知**（§4.3）。
- 検知結果・検索結果・改ざん検知ハッシュ連鎖（`sealed-manifest.sha256`）の状態を **htmx で配信する読み取り専用 Web UI**（§4.4）。
- 既存 `owl-audit-detect.sh` の webhook 通知経路（`/etc/owlv/audit-notify-webhook`、`<audit_notify_dst>`）を再利用した、統計的検知からの通報。

### 2.2 やらないこと

- 既存の `owl-audit-detect.sh`（閾値ベース即時検知）・`owl-audit-seal.sh`（封印・ハッシュ連鎖）の置き換え。両者は cron 駆動の軽量シェルスクリプトとして独立に存続させる（§5 で関係を整理）。
- ログの書き込み・削除・編集。`fohlen` はいかなる意味でも `/var/log/audit/` のデータ源にならない。
- owlv アプリ（Haskell/PostgreSQL/SQLite）側との直接連携。Audit VM は internal_lan / dev_lan から構造的に不可視であり（鉄則①）、`fohlen` がそれらへ問い合わせる経路を新設しない。
- 認証なしの公開 UI（§6.3 で最小限の認可を必須要件とする）。

---

## 3. アーキテクチャ概要

```
[AP/DB/Git/Build VM の syslogd] ──UDP/514 (鉄則①)──▶ [Audit VM syslogd]
                                                            │
                                                            ▼ 振り分け (syslog.conf)
                                              /var/log/audit/remote.log ◀── 既存・変更なし
                                                            │
                                          ┌─────────────────┼──────────────────┐
                                          │ tail (読み取り専用)                │ newsyslog (既存・変更なし)
                                          ▼                                    ▼
                                 ┌──────────────────┐               remote.log.N.gz (封印・sappnd)
                                 │      fohlen        │                        │
                                 │  (単一静的バイナリ)  │◀── 起動時/定期 取り込み ─┘
                                 │                    │
                                 │ ① ingest      (§4.1)│  生syslog行 → 構文要素への分解
                                 │ ② 正規化      (§4.1)│  構文要素 → AuditEvent（意味カテゴリ付き）
                                 │ ③ FTS index   (§4.2)│──▶ /var/db/fohlen/index.sqlite3 (新設・読み書き、生文字列+AuditEvent両方を索引)
                                 │ ④ stats engine(§4.3)│──▶ /var/db/fohlen/state/ (新設、AuditEvent のカテゴリ別ストリーミング統計を永続化)
                                 │ ⑤ htmx UI     (§4.4)│──▶ TCP listen (ホスト発のみ到達可能, §6)
                                 │ ⑥ webhook 通報       │──▶ <audit_notify_dst> (既存ホワイトリスト経由, 鉄則③)
                                 └──────────────────┘
```

①②の分離が本書の核心である。①は構文(誰がいつどのホストから何という tag で何を言ったか)を分解するだけで意味を判断しない。②が初めて「これは特権昇格の試みである」「これは認証成功である」といった**意味**を割り当てる。③④はいずれも①の生データではなく②の出力(`AuditEvent`)を主たる入力として動作する。

`fohlen` は Audit VM 上で1プロセスのみ起動する（`rcctl` 管理、`pidfile` で多重起動を禁止する既存パターン、[cron_batch.md §1](cron_batch.md) の `_owlbatch` daemon-likeパターンと同型）。専用サービスアカウント `_fohlen`（nologin、doasルールなし）で動作させ、`/var/log/audit` への読み取り権限のみ（グループ `wheel` 経由の読み取りビット、書き込み権限は持たない）と `/var/db/fohlen` への読み書き権限を与える。

---

## 4. 機能要件

### 4.1 イベント正規化（ドメインモデル）

これが §0.2 で述べた抽象化の実体である。取り込みは2段階に分ける。

**① ingest（構文分解、意味判断なし）**

- `remote.log` を末尾追記検出（`stat` によるサイズ監視、既存 `owl-audit-detect.sh` のオフセット方式と同じ考え方）でストリーミング取り込みする。ローテーション（サイズ縮小検出）時はオフセットを0へリセットし、ローテーション直前にまだ取り込んでいない末尾を最初に処理してから新ファイルへ追従する（取りこぼし防止）。
- 起動時（および新しい `.gz` 世代が `owl-audit-seal.sh` によって生成された検出時）に、未取り込みの封印済み世代を1回だけ取り込む。取り込み済み世代は世代ファイル名をキーに `/var/db/fohlen/state/ingested.json` 等へ記録し、再取り込みしない（冪等性、[cqrs.md §3.3](cqrs.md) のチェックポイント方式と同型の発想）。
- syslog 行のパース（OpenBSD `syslogd` 標準形式: `<timestamp> <hostname> <tag>[<pid>]: <message>`）を行い、送信元ホスト名（`ap_vm`/`db_vm`/`git_vm`/`build_vm`/host 自身を `pf.conf` のホスト名解決と対応付け）・facility/priority・tag・本文に分解する。この段階では構文要素 (`RawRecord{Timestamp, SourceHost, Facility, Tag, Message}`) を作るだけで、「これが何の事象か」はまだ判断しない。
- newsyslog による世代削除（30世代を超えた古い `.gz` の消滅）を検出した場合、対応する索引行を次回取り込みサイクルで削除する（索引はログの写しに過ぎず、原本が消えたら追従して縮小する。[cqrs.md §7](cqrs.md)「リビルド可能なキャッシュ」と同じ思想）。

**② 正規化（`RawRecord` → `AuditEvent`、意味の割り当て）**

`RawRecord` を、決定的なルールテーブル（tag・facility・message の正規表現マッチ、設定ファイルで追加・調整可能）によって有限のカテゴリ集合へ分類する。owlv の `Core.Event`（[CLAUDE.md](../CLAUDE.md) Recipe）が `decide`/`evolve` の入力になる前に生の取引文字列を型付きイベントへ変換するのと同じ立場であり、分類ルールが「何を異常とみなすか」(§4.3)の前提を固定する設計上の核である。

```go
type AuditEvent struct {
    Timestamp  time.Time
    SourceHost string        // "ap_vm" | "db_vm" | "git_vm" | "build_vm" | "host"
    Category   EventCategory // 有限集合。下記
    Actor      string        // 判別できた場合のみ(例: sshd "Accepted ... for alice")。空文字許容
    Raw        RawRecord     // 元の構文要素。全文検索・パース失敗時のフォールバックに使う
}

type EventCategory int
const (
    AuthSuccess               EventCategory = iota // sshd "Accepted"
    AuthFailure                                     // sshd "Failed", su/sudo "authentication failure"
    PrivilegeEscalationAttempt                      // su/sudo の失敗・doas拒否
    ConfigIntegrityDrift                            // owl-integrity-check.sh 転送分(tag=owl-integrity)
    SessionForceTerminated                          // owl-user-sync の pkill 実行ログ(user.md §3.1)
    Unclassified                                     // どのルールにも一致しない(下記参照、握り潰さない)
)
```

分類ルールテーブルは既存 `owl-audit-detect.sh`(§6.2実装、[setup.sh](../infra/vm-audit/setup.sh))が直接 `grep` していたパターン(`authentication failure`/`incorrect password`/`BAD SU`/`sshd.*Accepted`/`owl-integrity`)をそのまま移植して初期セットとする。**移植であって置き換えではない**——既存スクリプトは構文一致を直接アクションに繋げる薄い層として残し(§5)、fohlen はその同じ知識を型として再利用しつつ、統計エンジン(§4.3)が扱える有限のカテゴリ空間に格上げする。

`Unclassified` は**握り潰さない**。どのルールにも一致しなかった行はこのカテゴリで `AuditEvent` 化され、全文検索の対象には残る。一方、統計エンジンのベースライン計算(§4.3)からは除外する(異質なメッセージが混在するカテゴリを基準値計算に含めると統計量自体が汚染されるため)。代わりに Shannon エントロピー手法は `Unclassified` の**出現頻度そのもの**を監視対象にできる——「分類ルールでは捉えられない種類のログが増えている」こと自体を、新しいルールを書く前に検知できることが、ルールベース分類の限界に対する構造的な保険になる。

### 4.2 ログ取り込みの永続化と性能特性

- 索引エンジンは **`modernc.org/sqlite`（純 Go 実装、cgo 不使用）+ SQLite FTS5** を採用する。OpenBSD ネイティブビルドで cgo 依存（gcc 連携）を持ち込まない判断は、[hypervisor_rationale.md §1.1](hypervisor_rationale.md) の「複雑性は脆弱性の温床」という方針と、Build VM のツールチェーン構成を ports 標準の `go` のみに保つ意図の両方に合致する。
- **256MB 制約下でのメモリ管理を明示的に設計する**。`modernc.org/sqlite` は C版 SQLite と異なりGo の GC 管理下で動作するため、大量行の一括投入時に GC スパイクが発生しやすい。これを次の3点で抑える。
  1. **バルクコミット**: `AuditEvent` を1件ずつ `INSERT` しない。数千行(目安: 2000行、または取り込みサイクル1回分)単位でトランザクションをまとめ、コミット境界を明示する。1行ごとのトランザクションは WAL の fsync コストとオブジェクト生成数の両方を増やし、GC圧迫の主因になる。
  2. **`PRAGMA cache_size` を小さめに固定**: 接続初期化時(index.go の `Open` 直後)に `PRAGMA cache_size = -2000`(約2MBページキャッシュ。負値はKB指定)を明示する。デフォルトのページキャッシュ拡張に委ねない。
  3. **バルクコミット後の明示的 GC**: 各バルクコミット完了直後に `runtime.GC()` を呼び、コミット中に生成された一時オブジェクト(行バッファ、FTS5トークナイズ結果等)をその場で回収する。GCをランタイムの自動判断に委ねると、256MB環境ではコミットの合間にRSSが断続的に跳ね上がる(取り込みサイクルとGCサイクルの周期がずれることで、両者が重なる瞬間に一時的な倍のメモリ使用が起きうる)。
- 索引対象列: `timestamp`(検索・範囲フィルタ用、実列)、`source_host`、`category`(§4.1 の `EventCategory`、実列・索引対象)、`actor`、`message`(FTS5 全文索引列、`Raw.Message` 全体)。`view_account_balance` 的な「表示用と検索用の二重持ち」（[cqrs.md §5.3](cqrs.md)）は本データに金額がないため不要——ログ本文はそのまま1列で十分である。
- 検索 UI（§4.4）はキーワード（FTS5 MATCH 構文）・時間範囲・送信元ホスト・**カテゴリ**の組み合わせフィルタを提供する（旧版の `facility`/`tag` ベースのフィルタより、運用者が探したい対象(「特権昇格の試みだけ見たい」等)に直接対応する）。結果はページネーションし、一度に全件をメモリへ展開しない。
- 索引ファイルのディスク使用量上限は明文化しない（newsyslog の30世代保持と同じ期間だけ追従するため、原本ログの保持期間が事実上の上限になる）。ただし起動時に索引サイズが原本ログ合計サイズの一定倍数（目安: 3倍）を超えていないかをヘルスチェックでログ出力し、想定外の索引肥大（パースバグ等）を早期検知する。

### 4.3 統計的逸脱検知（学術的根拠を明示する）

機械学習モデルは§0.1の理由により採用しない。すべてオンライン（ストリーミング・定数メモリ）で計算可能な古典的手法のみを用いる。各手法は「何を異常とみなすか」を事前に数式で固定し、検知結果がその数式から再現可能であることを要件とする（IFRS側の「再計算すれば必ず合う」という[ifrs_standard.md](ifrs_standard.md)の設計思想と同じ立場を統計検知にも適用する）。**統計の対象は§4.1の `AuditEvent.Category` であり、生ログの構文要素ではない**——これにより閾値や統計量が「何が起きたか」という意味の単位で定義され、ログの言い回し(syslogタグの命名やメッセージ文言の細部)が変わっても分類ルールの修正のみで追従できる。

| 手法 | 出典・根拠 | 適用対象 | 検知する逸脱 |
|---|---|---|---|
| Welford のオンライン平均・分散更新 | Welford (1962) | カテゴリ別事象率の基礎統計量 | （単体では検知しない。下記2手法の入力） |
| Z-score / Shewhart 管理図（3σ規則・Western Electric Rules） | Shewhart (1931) の統計的工程管理 | 単位時間あたりの `AuthSuccess`/`PrivilegeEscalationAttempt` 件数 | 直近の値が移動平均から異常に離れている（点異常） |
| EWMA（指数加重移動平均）による管理図 | Roberts (1959) | 同上、特に緩やかなドリフト | 小さいが持続的な変化（閾値1点では拾えない傾向の変化） |
| CUSUM（累積和管理図） | Page (1954) | `PrivilegeEscalationAttempt`/`AuthFailure` の発生率 | 平均値の構造的なシフト（変化点検出） — 既存 `owl-audit-detect.sh` の「3回以上」固定閾値が捉えられない、閾値未満の事象が継続する攻撃を検知する |
| Shannon エントロピー / 自己情報量（サプライズ量 `-log2 p`） | Shannon (1948) | `(SourceHost, Category)` の出現頻度分布、および `Unclassified` の出現率 | 普段出現しない組み合わせ・未知のログパターンの増加を、事前学習済みモデルなしで検知する（観測頻度表のオンライン更新のみ） |

実装要件:

- 各手法はカテゴリキー(`(SourceHost, Category)` の組)ごとに独立した状態（平均・分散・EWMA値・CUSUM累積値・頻度表）を持ち、`AuditEvent` 1件ごとに定数時間で更新する。履歴イベントの再走査は不要（オンラインアルゴリズムの定義そのもの）。
- 状態は `/var/db/fohlen/state/stats.json`（または同等の永続化）に定期保存し、`fohlen` 再起動時に学習をやり直さない。
- 各手法の閾値（σ係数、CUSUM の許容偏差 `k` と検出閾値 `h`、EWMA の減衰係数 `λ`）は設定ファイル（`/etc/owlv/fohlen.toml` 等、`owl-config.toml` の `[audit]` セクションを拡張する形を想定）で調整可能にする。初期値は実機収集後に経験的に校正する（§10 残課題）。
- 逸脱検知時は §6.2 の既存方針を踏襲し、検知〜webhook送信を `fohlen` 内で完結させる。送信先は既存の `/etc/owlv/audit-notify-webhook` と `<audit_notify_dst>` をそのまま再利用し、新たな通知経路を増設しない。

### 4.4 配信（htmx UI）

- `net/http` + `html/template` による素朴なサーバーサイドレンダリング。JSフレームワークは導入せず、htmx 本体のみ `go:embed` でバイナリへ同梱する（§0.1）。
- 提供画面（読み取り専用、書き込み操作は一切提供しない）:
  - **検索**: §4.2 のキーワード・時間範囲・ホスト・カテゴリフィルタ。
  - **タイムライン/ダッシュボード**: §4.3 の各カテゴリの現在の統計量（移動平均・EWMA・CUSUM累積値）と、直近の逸脱検知イベント一覧。`AuditEvent.Category` 別に色分けし、`Unclassified` の出現率も常時表示する(§4.1の「ルールの限界に対する保険」を運用者が目視できるようにする)。
  - **改ざん検知状況**: `sealed-manifest.sha256`（[setup.sh](../infra/vm-audit/setup.sh) の `owl-audit-seal.sh` が生成するハッシュ連鎖）を読み取り表示し、連鎖の整合性（`prev=` の参照関係が途切れていないか）を `fohlen` 自身が再検証して合否を示す。**この検証はファイルの読み取りのみで完結し、`sealed-manifest.sha256` への書き込みは行わない。**
- すべてのページは htmx の `hx-get`/`hx-trigger="every Ns"` によるポーリングで部分更新する。WebSocket・SSE は採用しない（常時接続のリソース消費を避ける、256MB制約）。

---

## 5. 既存検知スクリプトとの関係

`owl-audit-detect.sh`（cron 1分間隔、固定閾値）と `fohlen`（常駐、統計的）は**並行して稼働させる**。どちらか一方への統合・置き換えは行わない。理由:

- `owl-audit-detect.sh` は依存が `grep`/`logger`/`curl` のみで構成され、`fohlen` のビルド・起動に失敗していても独立して機能する（フェイルセーフの多重化）。
- `fohlen` が検知する逸脱（CUSUMによる緩やかな変化点、エントロピーによる未知パターン）は、cron スクリプトの「直近チャンク内で3回以上」という単純カウントでは原理的に捉えられないクラスの異常であり、役割が重複しない。
- [dev_sec_ops.md §6.2](dev_sec_ops.md) の「検知から通報までを単一プロセス内で完結」という制約を両者がそれぞれ独立に満たす設計のほうが、一方のプロセスを経由する集約レイヤーを新設するより鉄則①・②に対する変更を最小化できる。

---

## 6. ネットワーク公開方式（ホスト発アクセスのみ）

[dev_sec_ops.md §6.1 鉄則①](dev_sec_ops.md)「Audit VM から他segmentへの通信は全ポート・全プロトコルで双方向遮断する」は **audit_lan が発信する側になることを禁じる規則であり、ホストが発信して audit_vm へ着信させることを禁じてはいない**。現在の `pf.conf` には audit_lan への着信ルールが syslog (UDP/514) 以外存在しないため、UI 用の新規ルールを追加する。

### 6.1 pf.conf への追加（ホスト → Audit VM のみ）

```
# infra/host/conf/pf.conf への追加(案) — fohlen UI への到達はホスト発のみ
pass out on $audit_veth proto tcp from (self) to $audit_vm port 9090 keep state
```

`vm-git` の Forgejo（[pf.conf:71](../infra/host/conf/pf.conf)「`pass out on $dev_veth proto tcp from (self) to $git_vm port 3000`」）と対になる、host-only の TCP 許可である。**他の3VM（AP/DB/Build）や外部 (`$wan_if`) からの直接アクセスは許可しない** — Forgejo が `build_vm`/`ap_vm` からも到達可能（[pf.conf:53,63](../infra/host/conf/pf.conf)）なのに対し、fohlen の UI はホストのみに絞ることで、鉄則①の「audit_lan は唯一どこからも信用できる踏み台にしない」という設計意図をより厳格に踏襲する。

### 6.2 開発者からホストへのトンネル経路

[dev_sec_ops.md §5](dev_sec_ops.md)「管理経路の極小化」はホストへの SSH を原則無効化し、許可する場合も「専用管理VLAN + Yubikey公開鍵限定 + `ForceCommand` による操作メニュー強制」を要求する。本UIの閲覧導線はこの制約の例外を増やさず、**既存の管理SSH経路に「ポートフォワード専用・シェル到達不可」の鍵を1本追加する**形で実現する（[vm-ap/setup.sh](../infra/vm-ap/setup.sh) の `ForceCommand` + `PermitTTY` の二段緊縛と同型の発想を、ホスト側の最小開口に適用する）。

```
# ホストの /root/.ssh/authorized_keys （または専用管理ユーザーの authorized_keys）
# fohlen 閲覧専用鍵: シェル不可・ポート転送先を audit_vm:9090 のみに限定
restrict,permitopen="10.0.3.10:9090" ssh-ed25519 AAAA... developer@laptop
```

`restrict` が `no-pty`/`no-X11-forwarding`/`no-agent-forwarding`/`no-port-forwarding` 等をまとめて否定し、`permitopen` で唯一許可するポート転送先を `audit_vm:9090` に限定する。開発者は次のコマンドで閲覧する。

```sh
ssh -N -L 9090:10.0.3.10:9090 -i ~/.ssh/fohlen_viewer host.owl.internal
# 別ターミナルまたはブラウザで http://localhost:9090/ へアクセス
```

この鍵はホストへの一般的な管理アクセス（§5 が想定する Yubikey + 専用管理VLAN 経路）とは**別系統**として発行する。同一鍵を使い回さない（最小権限の原則、[user.md §2.1](user.md) の「同一鍵を複数 `UserId` に登録することを拒否する」設計判断と同じ発想を鍵の用途分離にも適用する）。

### 6.3 UI 自体の認可（多重防御の最終層）

ネットワーク層の制限（§6.1, §6.2）に加えて、UI 自体も無認証では応答しない。**HTTP Basic 認証**（bcrypt ハッシュ化済み認証情報を `/etc/owlv/audit-ui-htpasswd` に配置、`fohlen` 起動時に読み込む）を最小要件とする。これは「どの層も単体では十分でない」という[tenant_isolation.md §3](tenant_isolation.md)/[cqrs.md §4.3](cqrs.md)で繰り返されている多層防御の思想を踏襲したものであり、SSH鍵漏洩単独でUI内容まで到達されることを防ぐ最後の一段である。TLS終端は持たない（同一LAN内の SSH トンネル内に閉じるため平文Basic認証で十分とする — Forgejo が 443 を使わず3000で平文運用している既存判断と同じ前提）。

---

## 7. データ配置とプロセス権限

```
/var/log/audit/                既存。fohlen は読み取り専用 (rpath相当)
  remote.log
  remote.log.N.gz               (sappnd 封印済み)
  sealed-manifest.sha256        (fohlen は読み取りのみ、書き込み主体は owl-audit-seal.sh のまま)

/var/db/fohlen/                 新設。_fohlen ユーザーが読み書き
  index.sqlite3                 FTS5 全文索引 (§4.2)
  state/
    ingested.json               取り込み済み世代のチェックポイント (§4.1)
    stats.json                  統計エンジンのオンライン状態 (§4.3)

/etc/owlv/
  fohlen.toml                   閾値・ポート等の設定 (新設)
  audit-ui-htpasswd             Basic認証情報 (新設、600, _fohlen所有)
  audit-notify-webhook          既存。fohlen も読み取り、通知先を共有
```

OpenBSD `pledge`/`unveil` の適用方針は既存の owlv アプリ（[cqrs.md §4.3](cqrs.md)）と対称的に設計する: `fohlen` は起動時に `unveil("/var/log/audit", "r")` ・ `unveil("/var/db/fohlen", "rwc")` ・ `unveil("/etc/owlv", "r")` を行う。`pledge` には `rpath wpath cpath inet stdio` 程度の最小集合のみを与える（`exec` は不要、外部プロセスを起動しない）。

**unveil 最終ロックのタイミング**: `unveil(nil, nil)`（以後のいかなる追加 unveil も拒否する最終ロック）は、上記3パスの unveil 宣言を終えた直後ではなく、**`modernc.org/sqlite` で `index.sqlite3` への接続(`sql.Open` → 実際に1クエリ発行して内部初期化を完了させた時点)を通過した直後**に行う。`modernc.org/sqlite` は内部実装上、一時ファイル(SQLiteのジャーナル/WAL関連)の作成先を `TMPDIR` 等の環境変数や `os.UserCacheDir()` 相当のパス解決に委ねている箇所があり、これらは `/var/db/fohlen` 配下に収まらない一時パスへ瞬間的に `open(2)` を試みる場合がある。3パス宣言の直後に最終ロックすると、この内部初期化が失敗して `unveil` 違反によるプロセス強制終了(SIGABRT、表面的には不可解なセグメンテーションフォールト的挙動として観測されうる)やパーミッションエラーに直結する。**起動シーケンスは「unveil 3パス宣言 → DB接続を開いて1クエリ通す → 必要なら `TMPDIR` を `/var/db/fohlen/tmp` に固定して当該パスも unveil → 最終ロック」の順を必須とする。**`TMPDIR` を明示的に `/var/db/fohlen/tmp` へ設定し、起動時に当該ディレクトリを作成・unveil 対象に含めておくことで、unveil 後に未知のパスへ依存する余地を構造的に塞ぐ。

---

## 8. テスト戦略

- **統計エンジンの単体テスト**: §4.3 の各手法について、既知の合成データ（定常系列 + 任意の時点に注入した変化点/外れ値）に対して期待どおりの検出有無・検出タイミングを確認する（Go の `testing` パッケージ、合成データのパラメータはテーブル駆動で複数ケース用意する）。オンライン更新の数式どおりに再現できることを検証するという点で、[ifrs_standard.md](ifrs_standard.md) 系の owlv 側 property test（debit=credit 再現性）と同じ「計算は決定的に再現できる」という要件を統計エンジンにも課す。
- **取り込みの冪等性テスト**: 同じ `.gz` 世代を2回取り込み手続きに通しても索引が重複しないこと（[cqrs.md §9](cqrs.md)「同じイベント列を2回プロジェクションしても結果が一致する」と同型のテスト）。
- **クラッシュ復旧テスト**: 取り込み中（チェックポイント更新前）にプロセスを `kill -9` し、再起動後に取りこぼし・重複が発生しないこと。
- **権限境界テスト**: `_fohlen` ユーザーで `/var/log/audit/remote.log` への書き込みを試み、拒否されることを確認する（OSレベルのパーミッションのみで成立させ、アプリ側のチェックに依存しない設計であることの確認）。
- **pf.conf 整合性テスト**: §6.1 の新規ルール適用後も、audit_lan から internal_lan/dev_lan への到達性が依然ゼロであることを [pentest_spec.md §1, §3-2](pentest_spec.md) の既存手順（`ping`/`nc -zv` による到達性確認）で再検証する。本書による変更が鉄則①を破っていないことを実機で確認する作業は、`fohlen` 実装完了後に pentest_spec.md へ新規テストIDとして追記する（§10 残課題）。

---

## 9. デプロイ（CI/CD、§3「残課題」の解決）

owlv 本体（AP VM）は [dev_sec_ops.md §4.2](dev_sec_ops.md) のプル型デプロイ（ホストが `deploy-poll` で定期検知 → AP VM へ SSH 経由でデプロイ指示 → AP VM が Git VM から自発的プル）を採用している。`fohlen` には同じ経路を**そのまま使えない**。理由は本書 §1 の制約条件そのものである。

- Audit VM は鉄則①（[dev_sec_ops.md §6.1](dev_sec_ops.md)）により dev_lan（Git VM）への通信を構造的に持たない。AP VM のように自分自身が Git VM からバイナリを取得しに行くことができない。
- Audit VM は [setup.sh](../infra/vm-audit/setup.sh) の末尾で自分自身の `pf.conf` を `chflags schg` 付きで default-deny に固定し、SSH 受信を含めて永久に自己ロックダウンする（§6.3）。ホストが AP/DB/Git/Build VM に対して行っている「ホスト → VM への恒久 SSH ルール」（[pf.conf](../infra/host/conf/pf.conf) の `pass out on $int_veth ... port 22` 等）に相当するものを Audit VM には張れない。

したがって `fohlen` の配信は **継続稼働中の `owl-control.sh deploy-poll`（cron 5分間隔）の対象から明示的に除外**し、代わりに **`infra/vm-audit/setup.sh` 自身（再実行可能な冪等スクリプト）が、プロビジョニング実行中——[04-pf-nat.sh](../infra/host/steps/04-pf-nat.sh) が一時的に audit_lan↔dev_lan を開けている、本番封鎖（[09-lockdown.sh](../infra/host/steps/09-lockdown.sh)）より前の時間帯——に Git VM のリリースレジストリから直接取得・検証・配置する**。これは「すべてベアメタルフルオートレストアの精神で `provision.sh` 内で実行される」という本プロジェクトの infra 方針（[CLAUDE.md](../CLAUDE.md)）にも合致する。再プロビジョニング（`setup.sh` の再実行）が `fohlen` の更新手段になる。

```
[Build VM の Forgejo Runner] ──push/merge──▶ build-fohlen.yml (infra/vm-git/)
    go vet / gofmt / go build / go test
    main へのマージ時のみ: タグ "fohlen-vX.Y.Z-<sha>" を付与
    fohlen-openbsd-amd64 + manifest.txt (未署名) を draft=true で Git VM へ
                                                          │
                                                          ▼ (既存の恒久ルール、§1.1.1)
[ホスト: owl-control.sh sign-poll] ──既存ロジックをそのまま再利用──▶
    owlv 本体・fohlen を区別せず、draft=true の manifest.txt を検知して
    ホスト保持の signify 秘密鍵で署名 → draft=false へ
                                                          │
                                                          ▼
[ホスト: owl-control.sh deploy-poll] ──tag が "fohlen-*" の場合のみ分岐──▶
    cmd_deploy(AP VM への SSH push)を呼ばず、既デプロイ台帳に記録するだけで
    スキップする(Audit VM へは構造的に push できないため)
                                                          │
                                                          ▼ (再プロビジョニング時のみ到達)
[vm-audit/setup.sh] (provision.sh STEP 8、本番封鎖前)
    1. Git VM の Releases API を "fohlen-" タグでフィルタし最新の draft=false を取得
    2. signify -V で /provision/release-signify.pub により manifest.txt を検証
    3. manifest.txt の uname_r と本機 uname -r の一致を検証
    4. fohlen-openbsd-amd64 の SHA256 が manifest.txt と一致することを検証
    5. 三重検証合格時のみ /usr/local/bin/fohlen_<tag> に配置しシンボリックリンク切替
    6. _fohlen サービスアカウント・/var/db/fohlen・rc.d 登録・起動
```

**signify 公開鍵の配布**: owlv 本体は AP VM への配置を「手動」としているが（[dev_sec_ops.md §4.2](dev_sec_ops.md) 手順3）、`fohlen` ではこの手動配置を `provision.sh` 自身に自動化した — [08-vm-provision.sh](../infra/host/steps/08-vm-provision.sh) が全 VM への通常のファイル転送に続けて `/etc/owlv/release-signify.pub`（公開鍵であり秘匿性は不要）を `/provision/release-signify.pub` として配布する。AP VM 側の手動配置を置き換えるものではない（両者は独立に存在してよい）。

**タグの名前空間分離**: owlv 本体のタグは `vX.Y.Z-<sha>`（[owlv.cabal](../owlv.cabal) の `version:` 由来）、`fohlen` のタグは `fohlen-vX.Y.Z-<sha>`（[infra/vm-audit/fohlen/VERSION](../infra/vm-audit/fohlen/VERSION) 由来）とし、同一 Forgejo リポジトリ内で衝突しないようにする。`sign-poll` は両者を区別せず一律に署名する（ホストは全成果物の唯一の信頼の根であり、対象を区別する理由がない）。`deploy-poll` は `fohlen-*` 接頭辞でのみ分岐する。

**Build VM のツールチェーン共存**: [vm-build/setup.sh](../infra/vm-build/setup.sh) は元々 `forgejo-runner` 自身を Go でビルドするため `pkg_add go` を行っていたが、`forgejo-runner` バイナリが既存の場合はその工程自体をスキップしていた。`fohlen` の CI は再実行のたびに `go` を必要とするため、`pkg_add go` をその条件分岐の外側（GHC と同じく無条件の位置）へ移した。Forgejo Runner には `go:host` ラベルを追加登録し、同一 Runner（capacity: 2）が `haskell:host`（owlv 本体）と `go:host`（fohlen）の両ジョブを処理する。

**ネットワーク到達性の補足修正**: 本書 §6.1 はホストから `audit_vm:9090` への到達を許可する pf ルールを提案していたが、実際の [pf.conf](../infra/host/conf/pf.conf) には未反映だった。今回これを追加し、合わせて `vm-audit/setup.sh` が書き込む Audit VM 自身の `/etc/pf.conf`（§6.3 の二重防御層）にも対になる `pass in proto tcp to port 9090` を追加した — ホスト側のみを許可しても、ゲスト自身の default-deny がポート 9090 を遮断したままでは UI に到達できないため、両方が揃って初めて意図通りに機能する。

---

## 10. 残課題

- **統計手法の閾値校正**: §4.3 のσ係数・CUSUM の `k`/`h`・EWMA の `λ` は実機のログ収集後に経験的に決める。初期値は保守的（誤検知を許容し見逃しを避ける）に設定し、運用しながら調整する。
- **Basic認証の認証情報のローテーション運用**: [pentest_spec.md §11](pentest_spec.md) のポストテスト手順と同様、定期ローテーションの運用規律を別途定める。`fohlen genpasswd <user> <htpasswd-file>` で既存ユーザーのパスワードを再生成できる（旧パスワードは即時失効）。
- **pentest_spec.md への新規テストケース追加**: §6.1 の新規 pf.conf ルールと §6.2 のホスト鍵制限が実機で意図通り機能するかを検証するテストIDを、`fohlen` 実装完了後に [pentest_spec.md](pentest_spec.md) へ追記する。
- **イベント分類ルールテーブルの拡充**: §4.1 の初期セットは既存 `owl-audit-detect.sh` の `grep` パターンをそのまま移植したものに過ぎない。実機ログのレビューを経て `AuthSuccess`/`AuthFailure` 以外のカテゴリ追加、メッセージ文言の揺れ(OpenBSDバージョン差異、[setup.sh](../infra/vm-audit/setup.sh) の検証注記と同じ懸念)への対応が必要。
- **`modernc.org/sqlite` のメモリチューニング値の実測確定**: §4.2 のバルクコミット件数(目安2000行)・`cache_size`(目安-2000)は実機ベンチマーク前の暫定値。256MB環境での実際のRSSピークを `vmstat`/`top` で観測し、GCスパイクが許容範囲(他サービスの動作に影響しない水準)に収まることを確認した上で確定する。
- **初回配置の手順**: §9 のデプロイ経路は Build VM の CI が一度も走っていない（または Git VM が DR 復元直後で `forgejo dump` を未だ復元していない）状態では「署名済みリリースなし」として安全にスキップする。実機での初回導入時は、(a) 実際に owlv リポジトリへ何らかの差分を push して `build-fohlen.yml` を一度走らせる、(b) `owl-control.sh sign-poll` の cron 周期(5分)を待つ、(c) `vm-audit/setup.sh` を再実行する、という3段の待ち合わせが発生する。DR 復元時系列（[dev_sec_ops.md §2.4](dev_sec_ops.md) 手順5「Git VM へ forgejo dump を復元する」は手順3「プロビジョニング」より後）との整合も含め、運用手順書側に明記する。
