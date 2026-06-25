# コントリビューションガイド

開発に参加する際の手順をまとめる。アーキテクチャ・ドメイン規約は [CLAUDE.md](CLAUDE.md)、機能実装の全体像は [README.md](README.md) を先に読むこと。コード上の「何が動いていて何が未実装か」も README に明記してあるので、そこから外れた前提で実装を始めないこと。

## 1. Git VM への参加（SSH 鍵）

このリポジトリの Forgejo（Git VM）には外部から直接 SSH できない。ホストの no-shell な `git-jump` アカウントを踏み台にした SSH トンネル経由でのみアクセスする（[infra/host/security/dev-join.sh](infra/host/security/dev-join.sh)、[infra/host/steps/01-host-foundation.sh](infra/host/steps/01-host-foundation.sh)）。新規メンバーの参加は以下の2手順で完了する。

### ① 開発メンバー（自分）がやること

まだリポジトリへの push 権を持っていないため、鍵は自分でコミットせず、開発責任者へ渡す。

```sh
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_gitjump -C "<username>-gitjump"
```

- `git-jump` 専用の鍵を新規生成する。ホスト管理者用 SSH/rsync の鍵とは別物にする。
- **パスフレーズは必須**。秘密鍵をローカルで保護するための最後の手段なので、空パスフレーズで運用しない。
- `username` は OpenBSD `useradd` の制約に合わせ、英小文字始まり・英小文字/数字/`-`/`_` のみにする。

生成した `~/.ssh/id_ed25519_gitjump.pub` の**内容**を、何らかの安全な手段（対面・既存の認証済みチャネルなど。秘密鍵自体は絶対に渡さない）で開発責任者に渡す。

### ② 開発責任者がやること

1. 受け取った公開鍵を `infra/host/conf/git-jump-keys/<username>.pub` として追加し、コミット・push する（インフラはコードから 100% 再生成可能に保つ方針、§4.3）。
2. ホストへ SSH で入り、root（`doas`）で同期スクリプトを実行する。

   ```sh
   doas sh dev-join.sh sync
   ```

   `*.pub` ファイルと OS アカウントの状態を一致させる冪等処理で、追加・退会のどちらも自動的に反映される。個別に1人だけ即時反映したい場合は `doas sh dev-join.sh <username> infra/host/conf/git-jump-keys/<username>.pub` でも同じ結果になる。

これだけで OS アカウント作成・`authorized_keys` 登録まで完了し、開発メンバーは追加の連絡を待たずに次の手順で接続できる（最初に聞かれるのは①で自分が決めた鍵のパスフレーズのみ）。`git-jump` アカウントはシェルを持たず、`PermitOpen` で Git VM の `:22`（git push 用）と `:3000`（Forgejo Web UI 用）への転送だけが許可されている。

### Web UI を見る

```sh
ssh -i ~/.ssh/id_ed25519_gitjump -N -L 3000:<GIT_VM_IP>:3000 <username>@<ホストのLAN IP>
```

接続したまま別ターミナルでブラウザから `http://localhost:3000` を開く（`<GIT_VM_IP>` は責任者から伝えられた Git VM の dev_lan 上の IP。`<ホストのLAN IP>` も同様）。

### git clone / push する

毎回ポートフォワードを張る代わりに、`~/.ssh/config` に以下を追記すると `ProxyJump` で直接 SSH できる。

```sshconfig
Host owlv-jump
    HostName <ホストのLAN IP>
    User <username>
    IdentityFile ~/.ssh/id_ed25519_gitjump

Host owlv-git
    HostName <GIT_VM_IP>
    User git
    ProxyJump owlv-jump
```

これで通常の `git@<git_vm>` と同じ要領で操作できる。

```sh
git clone ssh://owlv-git/owlv-admin/owlv.git
# 既存の clone に remote を向け直す場合
git remote set-url origin ssh://owlv-git/owlv-admin/owlv.git
```

退会させる場合は `infra/host/conf/git-jump-keys/<username>.pub` を消してコミットし、責任者がホスト上で `dev-join.sh sync`（または `dev-join.sh <username> --remove`）を実行するだけでよい。

## 2. Pompadour bot（ChatOps）

Git VM 上で稼働する Bot で、Issue/PR コメントから以下のコマンドを受け付ける（[infra/vm-git/pompadour/README.md](infra/vm-git/pompadour/README.md) に詳細）。

| コマンド | 振る舞い |
| --- | --- |
| `/assign` または `/assign @user` | 引数のユーザー（省略時は投稿者自身）をレビュアーに指定 |
| `/help wanted` | `help wanted` ラベルを付与し、Onboarding 案内コメントを再掲 |
| `/hold` | `do-not-merge/hold` ラベルを付与し、Merge Queue から即時除外 |
| `/release-note <text>` | コメントとして整形転記（PR 本文は書き換えない） |
| `/retest` | 即時コメントのみ返す（実際の CI 再実行は未実装） |

権限チェックはコメント本文を信用せず、毎回 Forgejo の collaborator 権限を照会する。コラボレータ以上が前提。

その他に知っておくと良いこと:

- **初回 PR**: そのリポジトリで初めて PR を出すと判定されると、Onboarding 案内コメントが自動で付く。
- **自動ラベリング**: ラベル無しの open issue は `ai-suggested/<category>` という提案ラベルが付き、72時間放置すると確定ラベルへ自動昇格する。
- **Merge Queue**: 現状 `main` への自動マージは発生しない（CI トリガーが未実装のため常にエラーを返す）。ブランチ保護の必須 approval は Pompadour とは独立して効いているので、レビュー承認自体は通常通り必要。
- **Knowledge Harvest**: マージ済み PR 本文の `## Why` セクションを機械的に `doc/decision-log/decision-log.md` へ転記する。**PR 本文に `## Why` を書く習慣をつけること**（解釈・要約はされないので、why はこちらで言語化しておく）。アーキテクチャ判断を含む文言（architecture/トレードオフ/方針 等）があると ADR 起票を促すコメントが付くが、ADR 自体は人間が `doc/adr/` へ手動コミットする。

## 3. ローカルでの検証環境（Docker）

開発機に Docker を入れておくと、本番の OpenBSD VM 構成を意識せずに素の PostgreSQL + アプリで動作確認できる（[docker-compose.yml](docker-compose.yml)、[Dockerfile](Dockerfile)）。

```bash
docker compose up -d db          # PostgreSQL コンテナ起動（pg_isready 待ち）
docker compose build app         # ソース変更後は明示的に再ビルド
docker compose run --rm app      # TUI を起動して動作確認
```

DB の接続情報は Docker ネットワーク内のサービス名 `db` で固定済み。開発用パスワードのみリポジトリに平文で置いてよい（本番値は絶対に書かない）。

Haskell ツールチェーンを直接使いたい場合は Docker 無しでも開発できる。

```bash
cabal build
cabal test --test-options='-p "<pattern>"'   # 単体テストはこちらを優先
fourmolu -i $(git ls-files '*.hs')
hlint app src test
```

`Core/` のテストはインフラ不要で CI 実行対象。`Shell/`（PostgreSQL 永続化・TUI 描画）の動作確認は上記の Docker 環境での手動確認のみで、cabal のテストスイートには含めない。

## 4. 機能を追加するときの作法

ドメインロジック（仕訳・固定資産・ECL 等）を変更・追加する場合は、必ず先に [doc/ifrs_standard.md](doc/ifrs_standard.md) の該当節を読み、IFRS 解釈に曖昧さがあれば実装前に質問すること（独自解釈で進めない）。実装の手順は [CLAUDE.md](CLAUDE.md) の「Recipe for adding a feature」に固定されている（`Core/Command.hs` → `Core/Event.hs` → `decide` → `evolve` → property test の順）。`Shell/` を変更する必要が出た場合は、まず変更が必要な理由を説明してから着手する。
