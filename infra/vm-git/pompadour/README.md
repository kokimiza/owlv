# Pompadour

Git VM 上で稼働する Contributor Relationship Management Bot。`infra/vm-git/setup.sh` の
リポジトリ作成・ブランチ保護設定が**前提条件**。

## Forgejo 側の事前設定

Pompadour 自身はラベル・ブランチ保護・Bot アカウントを作成しない(既存の
ものを読み書きするだけ)。起動前に以下を手動で用意する。

1. **Bot トークン**: `infra/vm-git/setup.sh` と同じ要領で、用途を絞った
   `write:issue` + `write:repository` スコープのトークンを発行し、
   `POMPADOUR_FORGEJO_TOKEN`(既定の env var 名)へ設定する。`admin` 等の
   過剰スコープは持たせない。
2. **ラベル**: 以下を `Settings > Labels` で事前作成しておくこと。
   `AddLabels` は名前解決に失敗したラベルを黒く無視する(エラーにせず
   何もしない)ため、存在しないラベルは静かに付与されない。
   - `help wanted`、`do-not-merge/hold`、`needs-reviewer`
   - `ai-suggested/bug`、`ai-suggested/security`、`ai-suggested/enhancement`、
     `ai-suggested/documentation`、`ai-suggested/good-first-issue`
     (確定後に付く `bug`/`security`/... の素のラベルも同様に必要)
3. **ブランチ保護**: `main` の必須 approval(dev_sec_ops.md §3.3)は
   `setup.sh` で設定済みの前提。Pompadour の Merge Queue はこの上に乗る
   だけで、approval チェック自体を代替・迂回しない。
4. **`/etc/owlv/pompadour.toml`**: `[forgejo] owner/repo/token_env`、
   `[reviewer] pool`(レビュアープールは空文字列のままなら Review
   Balancer は何もしない — 人間が明示的にプールを設定するまで自動アサイン
   は始まらない、doc/pompadour.md §5.6)を記入する。全キー省略可
   (`internal/config.Default()` 参照)。

## ビルド(Build VM、ネイティブ `lang/go`)

```sh
go build -o pompadourd ./cmd/pompadourd
go build -o ai-gateway ./cmd/ai-gateway
go test ./...
```

`go.sum` は committed 済み(`go build`/`go vet`/`go test ./...` 全て pass)。
`import` を変更したときだけ `go mod tidy` を再実行する。

## 実行

```sh
POMPADOUR_FORGEJO_TOKEN=xxxx ./pompadourd
```

起動後は Forgejo への**ポーリングのみ**で動く(Webhook 受信は無い、
doc/pompadour.md §3)。`pompadourd` 自身は機能ごとに別間隔でループし、
ログに `pompadourd: started, polling <owner>/<repo> as <base_url>` が出れば
正常起動。

`ai-gateway` は単独では実行しない(下記「注意」参照)。`pompadourd` から
`internal/pinhole` 経由で都度起動される前提で、`AI_GATEWAY_ENDPOINT` /
`AI_GATEWAY_API_KEY` の 2 つの環境変数を要求する。

## Forgejo 上での振る舞い

### ChatOps(`internal/chatops`、Issue/PR コメントから)

| コマンド | 振る舞い | 権限 |
| --- | --- | --- |
| `/assign` または `/assign @user` | 引数のユーザー(省略時はコメント投稿者自身)をレビュアーに指定 | コラボレータ以上 |
| `/help wanted` | `help wanted` ラベルを付与し、Onboarding 案内コメントを再掲 | コラボレータ以上 |
| `/retest` | 「CI 再実行をキューに入れました」と即時コメント(実際の再実行 API 呼び出しは未実装、下記「注意」) | コラボレータ以上 |
| `/hold` | `do-not-merge/hold` ラベルを付与し、Merge Queue から即時除外 | コラボレータ以上 |
| `/release-note <text>` | コメントとして整形転記するのみ(PR 本文の書き換えはしない) | 誰でも(投稿者自身の release-note として扱う) |

権限チェックはコメント本文を信用せず、毎回 Forgejo の
`collaborators/{user}/permission` を照会して確認する(なりすまし防止)。
認識しないコマンドや権限不足のコマンドは無視またはエラーコメントを返す。

### 自動ラベリング(`internal/labeler`)

ラベルが一つも付いていない open issue を見つけると、`ai-gateway` 経由で
`bug`/`security`/`enhancement`/`documentation`/`good-first-issue` の中から
分類し、`ai-suggested/<label>` という**提案ラベル**を付ける(確定ラベルは
即座には付かない)。72 時間放置されると自動的に確定ラベルへ昇格し、提案
ラベルは外れる。

### Onboarding(`internal/onboarding`)

PR 作者がそのリポジトリで初めて PR を出した人物だと判定すると(過去の
PR 件数 0)、開発環境・コーディング規約への案内コメントを自動投稿する。

### Merge Queue(`internal/mergequeue`)

`Mergeable` な open PR を自動でキューに enqueue し、FIFO 順に最大 3 件を
バッチで CI にかけ、通過したバッチをまとめて `rebase` merge する。失敗時は
二分探索(`internal/batch`)で原因 PR を特定し、そのPRだけ `failed` として
キューから除外・コメント、残りは次サイクルへ再投入する。

### Review Balancer(`internal/reviewbalancer`)

レビュアー未指定の open PR に対し、`[reviewer] pool` の中で最も負荷の低い
メンバーを自動 request する。プール全員が `max_assigned_count` に達して
いる場合は誰にも割り当てず、`needs-reviewer` ラベルを付けるだけに留める。

### Knowledge Harvest(`internal/harvest`)

マージ済み PR の本文から `## Why` セクションを抜き出し、
`doc/decision-log/decision-log.md` へ機械的に転記する(解釈・要約はしない)。
アーキテクチャ判断を示す語(architecture/トレードオフ/方針 等)を含む場合は
`doc/adr/` への起票を促すコメントを残すのみで、**ADR 自体は自動コミットしない**
——人間が `/adr-confirm` する前提(現状 `/adr-confirm` ハンドラ自体は未実装)。

## 注意

- **`ai-gateway` は `pompadourd` から直接 import されない別バイナリ**。
  `pompadourd` 自身は LLM API への outbound を一切持たず、ホスト側の
  時限ピンホールスクリプト(`owl-control.sh` 系、未実装・本リポジトリの
  範囲外)経由でのみ `ai-gateway` を起動する設計(doc/pompadour.md §7)。
  この分離を壊して `ai-gateway` のロジックを `pompadourd` に統合しない。
- **Merge Queue の CI トリガーは未実装**(`cmd/pompadourd/main.go` の
  `runScratchBranchCI`)。スクラッチブランチ作成・削除と bisect ロジック
  自体はテスト済みで動くが、Forgejo Actions の実行・結果ポーリングへの
  接続はまだ TODO。現状は常にエラーを返し、main へのマージは発生しない。
- **`/adr-confirm` ハンドラは未実装**。`internal/harvest.ADRDraftComment`
  がコメントを残すところまでで止まり、人間が ADR を実際に
  `doc/adr/` へコミットする操作自体は本リポジトリの範囲外(手動)。
- **ブランチ保護はこのデーモンでは代替しない**。Merge Queue・Review
  Balancer はいずれも Forgejo 自体の必須 approval チェック
  (dev_sec_ops.md §3.3)の上に乗る前提で書かれている。このデーモンの
  バグでブランチ保護を迂回できてはならない(doc/pompadour.md §7)。
- AI ラベル分類(`internal/labeler`)はモデル出力を `Categories`
  の閉集合へ必ずフィルタする。新しいカテゴリを増やす場合は
  `internal/labeler.Categories` と `doc/pompadour.md §4.2` を同時に更新する。
