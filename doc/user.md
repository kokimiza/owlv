# ユーザー管理 基本設計書

## 0. この文書の位置づけ

owlv における「ユーザー」は二つの世界に同時に存在する。

1. **OS（OpenBSD・AP VM）側のアカウント** — SSH ログインの実体。[infra/vm-ap/setup.sh](../infra/vm-ap/setup.sh) の `add-owl-operator` / `add-owl-maintainer` で、保守者が手動で `useradd` している。
2. **owlv アプリ側のユーザー** — 画面アクセス制御（[src/Core/Domain/OrgPermission.hs](../src/Core/Domain/OrgPermission.hs) の `PermScope`）や仕訳の入力者・承認者識別（[ifrs_standard.md](ifrs_standard.md) §2.1.1 486行）に必要だが、**現状は存在しない**。`Shell.Interpreters.UserContext.runUserCtxPg` は RLS 用の `app.current_user` を文字列でセットするだけで、その文字列の正当性を誰も検証していない（[src/Shell/TUI/Submit.hs](../src/Shell/TUI/Submit.hs) は `runUserCtxFixed "system"` 固定、[batch/Batch/Env.hs](../batch/Batch/Env.hs) は `"batch"` 固定）。

この文書は、上記2つを**Haskell側のUserマスタを単一の真実源（Single Source of Truth）として一方向に統合する**基本設計を定める。dev_sec_ops.md・vm-ap/setup.sh への実装反映は別タスクとし、ここでは設計のみを確定する。

## 1. 課題（現状の二重管理リスク）

| リスク | 現状の原因 |
|---|---|
| 退職者の OS アカウントだけ残る | OS 側の削除は保守者が手動で行う別作業であり、アプリ側に削除を知らせる経路がない |
| アプリ側ユーザーだけ残り、SSH 不可なのに画面権限が有効に見える | アプリにユーザーという概念自体が存在しない |
| 「誰が起票したか」を `app.current_user` の生文字列に依存している | OS ログインユーザー名がそのまま信用されており、失効・改名・なりすましを検出できない |
| 権限変更が二箇所（`usermod -G` とアプリ内 ACL）に分散し、整合性確認の手段がない | 単一の状態機械が存在しない |

方針は一つ：**ユーザーのライフサイクル（作成・権限変更・停止・削除）はすべて owlv アプリ内のコマンドとして発行し、OS 側はその投影（projection）として一方向に同期される。** OS 側で直接 `useradd`/`userdel` を打つ運用は廃止する。

## 2. ドメインモデル（Core）

新規アグリゲート `User` を [src/Core/Domain/User.hs](../src/Core/Domain/User.hs) に追加する（CLAUDE.md の「Recipe for adding a feature」に従う）。

```haskell
newtype UserId = UserId Text  -- = OS ユーザー名そのもの（後述、不変）

data Role = Operator | Maintainer | Admin
  -- Operator   = owl-operators 相当（ForceCommand 直行、シェル不可）
  -- Maintainer = owl-maintainers 相当（ksh シェル、参照中心）
  -- Admin      = owlv 内のユーザー管理コマンドを発行できる役割

data UserStatus
  = Pending     -- 作成イベントは記録されたが OS 同期が未完了
  | Active      -- OS 同期成功・SSH 可能
  | Suspended   -- 一時停止（OS 側ロック済み、削除はしない）
  | Removed     -- 削除済み（終端状態、復活は新規 UserId で）

data User = User
  { userId        :: UserId
  , userDisplayName :: Text
  , userRole      :: Role
  , userStatus    :: UserStatus
  , userScopes    :: [PermScope]       -- 既存 Core.Domain.OrgPermission を再利用
  , userPasswordHash :: Maybe Text     -- Argon2id ハッシュ。§3 参照。SSH 認証には使わない
  , userSshPubKeys :: [Text]           -- authorized_keys に展開する公開鍵（§2.4 のオプション禁止を適用済みのもののみ）
  }
```

**全コマンドは発行者 (`actor :: UserId`) を必須項目として持つ。** これが欠けると「誰が起票したか」を求める ifrs_standard.md §2.1.1 の要件をユーザー管理自身が満たさないという自己矛盾になる。`decide` は次を強制する：

- `actor` は `Status == Active` かつ `Role == Admin` でなければ `CreateUser`/`ChangeUserRole`/`RemoveUser` 等の管理コマンドを `decide` が拒否する（権限のない/失効済みアクターによる発行をブロック）。
- `ChangeUserRole _ Admin`（Admin への昇格）は単独の `decide` 承認では `Active` にならず、**二人目の Admin による `ApproveRoleEscalation` を追加で要求する**（dual control）。実装は既存 [Core/Domain/JudgmentLog.hs](../src/Core/Domain/JudgmentLog.hs) の判断ログ機構を流用し、最高権限への昇格を単独行為にしない。

**Admin の最初の1人（鶏卵問題の解決）**：`decide` にブートストラップ例外は設けない。代わりに、`Admin` ロールを持てる `UserId` は **`owl-config.toml` に静的に記載された1つの予約済みユーザー名（`[user] root_admin_username`）のみ**とし、その専用 OS アカウントは従来通り [infra/provision.sh:14-20](../infra/provision.sh#L14-L20) の手順（保守者が物理コンソール/初回 SSH で `useradd`/`usermod -G wheel`）で作る。owlv アプリは「`root_admin_username` と一致する `UserId` で SSH 接続が確立した（§4.1）」場合に限り、`User` 射影が存在しなくてもその場で `Admin`・`Active` な `User` を自動生成する（唯一の自己ブートストラップ経路）。それ以外の `UserId` は `actor` に既存 Admin を要求する通常ルールのまま。つまり **Admin への昇格経路は「専用ユーザーを `usermod` で作り、そのユーザーで SSH した時だけ」の1本に絞る。** これにより `CreateUser`/`ChangeUserRole _ Admin` 経由でAdminを増やす一般ルートと、最初の1人だけの特例ルートが明確に分離される。

### 2.1 不変条件（`decide` に実装）

- `UserId` は POSIX ユーザー名制約（`^[a-z_][a-z0-9_-]*$`、31文字以内）を満たし、一度発行したら**不変**。OS 側のユーザー名と1:1で対応させるための制約であり、改名はできない（改名したい場合は新規作成＋旧ユーザー `Removed`）。
- `UserId` はシステム全体で一意（既存 `Removed` ユーザーの ID も再利用不可 — イベントストアは append-only であり、過去の `UserCreated` と矛盾するイベントを作れないため）。
- `Pending → Active` の遷移は OS 同期成功イベント（`UserOsSyncSucceeded`）でのみ起こる。アプリ側だけで `Active` を自称することはできない。
- `Suspended`/`Removed` への遷移は常に許可（緊急停止を権限の確認待ちにしない）。
- `Removed` は終端。`Removed` から `Active` へは戻せない。
- `userPasswordHash` を更新するコマンドはハッシュ済みの値のみを受け取る（ハッシュ計算は副作用なので Shell が事前に計算し Core に渡す — sandwich pattern、CLAUDE.md 既存方針と同様）。
- `RegisterUserSshKey` は鍵文字列に `command=`/`environment=`/`permitopen=`/`no-pty` 等の**オプション接頭辞を含む鍵を拒否する**（`decide` で正規表現検証）。sshd_config の `ForceCommand`（[vm-ap/setup.sh:106](../infra/vm-ap/setup.sh#L106)）はサーバー側設定が常に優先されるため実害は限定的だが、Maintainer はフルシェルを持つため per-key オプションによる権限変更の余地を最初から塞ぐ。同一鍵（同一フィンガープリント）を複数 `UserId` に登録することも拒否する（鍵共有は身元の一意性を崩す）。
- `UserId` の OS UID は Core が**単調増加カウンタから明示的に割り当てる**（`useradd` の自動採番に委ねない）。`Removed` になった `UserId` の UID は再利用しない。理由：UID 再利用時、削除済みユーザーが所有していたファイルの所有権が新規ユーザーに引き継がれる事故を構造的に防ぐ（cron_batch.md が `_owlbatch` に固定 UID 800 を明示しているのと同じ理由）。

### 2.2 コマンド / イベント

| Command | Event |
|---|---|
| `CreateUser UserId DisplayName Role [PermScope]` | `UserCreated` |
| `ChangeUserRole UserId Role` | `UserRoleChanged` |
| `GrantUserScope UserId PermScope` / `RevokeUserScope UserId PermScope` | `UserScopeGranted` / `UserScopeRevoked` |
| `SetUserPasswordHash UserId Text` | `UserPasswordChanged` |
| `RegisterUserSshKey UserId Text` | `UserSshKeyRegistered` |
| `SuspendUser UserId` | `UserSuspended` |
| `ReactivateUser UserId` | `UserReactivated` |
| `RemoveUser UserId` | `UserRemoved` |
| *(Shell が OS 同期結果を反映する内部イベント、後述§4)* | `UserOsSyncSucceeded` / `UserOsSyncFailed` / `UserOsDriftDetected` |
| *(Shell が SSH ログインを観測した結果、後述§5)* | `UserLoginObserved` |

`evolve` はこれらを `User` の射影に畳み込む。`decide` には新規 5 つの不変条件チェックを追加し、CLAUDE.md の指示通り各ブランチに property test（特に「`Pending` 以外からの `UserCreated` 再発行を拒否」「`Removed` からの遷移をすべて拒否」）を書く。

### 2.3 パスワードの位置づけ（誤解しやすい点）

vm-ap の sshd 設定（[infra/vm-ap/setup.sh:101](../infra/vm-ap/setup.sh#L101)）は `PasswordAuthentication no` である。つまり **owlv の `userPasswordHash` は SSH ログインの認証要素ではない**。SSH の認証は今後も OS 側の公開鍵認証に委ねる。

`userPasswordHash` の用途は、ifrs_standard.md §2.1.1 が要求する「入力者と承認者による内容確認」（486行）のような**アプリ内のステップアップ確認**（例：承認操作の直前に本人確認として再入力させる）に限定する。ネットワークを跨がず、既に確立済みの SSH/TUI セッション内でのみ検証されるため、新たな攻撃面を増やさない。

イベントストアは append-only で恒久保存されるため、ハッシュであっても永久に残る点に注意する。Argon2id のコストパラメータを将来的に強化する際、過去イベントのハッシュは旧パラメータのまま残る（再ハッシュできない）。これは許容するが、**パスワード関連イベントだけ別の鍵で暗号化されたカラムに退避する**選択肢も§7で未決事項として残す（ブラスト半径を会計イベントと分離する意味がある）。

## 3. OS 側との同期（一方向プロジェクション、ただし"言ったことを信じない"）

```
[owlv アプリ: CreateUser コマンド]
        │ decide → UserCreated イベント追記（PostgreSQL イベントストア）
        ▼
[Shell: UserOsSyncEff]
        │ User 射影から OS 側の望ましい状態を算出
        │ （ユーザー名・公開鍵・Role→OSグループ対応・Status→ロック状態）
        │ ※冪等キー = UserCreated 等の元イベントのイベントID。同じ
        │   イベントIDに対する owl-user-sync 呼び出しは何度再試行しても
        │   同一の最終状態に収束させる（リトライによる多重適用を防止）。
        ▼
[doas owl-user-sync --apply <json>]   ← AP VM ローカル、ネットワーク越えなし
        │ useradd / usermod / userdel・authorized_keys 書き込みを冪等に実行
        │ 結果を構造化して標準出力へ（自己申告であり信用しない）
        ▼
[Shell: 同じ effect が /etc/passwd・authorized_keys・group を
        読み取り専用で再確認し、望ましい状態と実際の状態が一致して
        初めて UserOsSyncSucceeded を追記する]
```

**スクリプトの「成功しました」という自己申告だけで `UserOsSyncSucceeded` を確定しない。** `owl-user-sync` 自体が侵害されている場合、標準出力で成功を偽装できる。Shell は同期コマンド実行後に**別の読み取り専用パスで** OS の実際の状態（`getent passwd`、`authorized_keys` の内容）を取得し、望ましい状態と独立に突合してから初めてイベントを確定する。これは§4.2のドリフト検知（定期実行）とは別物——こちらは**同期の直後・即時の事後検証**であり、毎回必ず行う。

**OS同期が途中でクラッシュした場合の再試行ポリシー：** `Pending` のまま放置されたユーザーは、次回バッチ（§4.2 と同じ `owlv-batch-center` ジョブ）が自動的に同じ冪等キーで再試行する。N回（既定3回）失敗した `Pending` は自動リトライを止め、`UserOsSyncFailed` を確定して人間の介入を要求する（40分ハングの教訓と同じく、無限リトライにしない）。

### 3.1 `owl-user-sync`（新規ヘルパー、既存スクリプトの統合）

[infra/vm-ap/setup.sh](../infra/vm-ap/setup.sh) の `add-owl-operator` / `add-owl-maintainer`（58–85行）を、引数駆動・冪等な単一ヘルパー `/usr/local/sbin/owl-user-sync` に統合し置き換える。

```sh
# 例: owlv-app が doas 経由で呼ぶ
owl-user-sync --apply '{"username":"alice","role":"Operator","status":"Active","ssh_keys":["ssh-ed25519 AAAA..."]}'
```

挙動：
- `status=Active` かつアカウント未存在 → `useradd -u <Coreが割り当てた固定UID> -m -G <role対応グループ> -s <role対応シェル>` + `authorized_keys` 書き込み
- `status=Active` かつ既存 → 差分（グループ・鍵）のみ更新（冪等）
- `status=Suspended` → アカウントは残すが `usermod -L`（パスワードロック）+ `authorized_keys` を空にする（鍵ベース認証しかないため、ロックだけでは SSH を止められない。鍵を外すことが実効的な遮断手段）
- `status=Removed` → `userdel -r`
- **`Suspended`/`Removed` のいずれも、`authorized_keys` 書き換えの直後に `pkill -u <username>` を実行し、その瞬間に確立済みの SSH/TUI セッションを強制切断する。** これがないと「権限を止めたつもり」でも既存セッションは生き続け、停止が完了するまでの間アクセスを許してしまう。`infra/host/sbin/owl-pfctl-pinhole`（host側の同種の遮断機構）と対になる、AP VM側の即時遮断として位置づける。

### 3.2 doas 境界（cron_batch.md の既存パターンを継承）

[cron_batch.md](cron_batch.md) の `_owlbatch` と同じ「デフォルト全拒否、許可は1行だけ」の設計を踏襲する。

```
# /etc/doas.conf (AP VM)
# owlv-app（owlv TUI を動かす実行ユーザー）にのみ、このヘルパー1本だけを許可する。
# owl-operators / owl-maintainers には doas を一切許可しない（昇格経路ゼロ）。
permit nopass owlv-app cmd /usr/local/sbin/owl-user-sync
```

これにより、TUI 経由でアカウントが乗っ取られても、`owl-user-sync` が受理する JSON のスキーマ以外の操作はできない。Yubikey による SSH 層の保護（dev_sec_ops.md §1.1.1）とは独立した境界として機能する。

## 4. 認証状態の観測（OS → アプリへの逆方向フィードバック）

「SSH確立済みなのか、ホスト側から消えてるのか」をアプリ側が知るための2つの経路。

### 4.1 ログイン観測（リアルタイム）

[infra/vm-ap/setup.sh:45](../infra/vm-ap/setup.sh#L45) の `owl-session` ラッパーは `ForceCommand` として sshd から直接 exec される。sshd は接続元の OS ユーザー名を環境（`$USER`/`whoami(1)`）で確定済みの状態で渡すため、`owlv-app` 起動時にそれを読み取り、**Core の `User` 射影と突き合わせてから** TUI を開始する：

1. `whoami` で `osUser` を取得
2. `User` 射影を `osUser` で検索。存在しない、または `Status /= Active` なら **TUI を起動せず即終了**（OS 側でロックし忘れていても、アプリ側がもう一段の門番になる）
3. 一致すれば `UserLoginObserved UserId Timestamp SourceIp` を追記し、`runUserCtxPg` の `uid` にこの `UserId` を使う（現状の `"system"`/`"batch"` 固定をここで置き換える）

これにより RLS の `app.current_user` が初めて「検証済みの owlv ユーザー」に紐づく。

### 4.2 ドリフト検知（定期検証、フェイルセーフ）

同期は基本的に成功するはずだが、手動オペレーションや障害復旧で OS 側が直接触られた場合に備え、既存の改ざん検知パターン（[infra/host/steps/07-lockdown.sh](../infra/host/steps/07-lockdown.sh) の `integrity-baseline.sha256`、cron_batch.md の定期バッチと同じ思想）を流用する：

- `owlv-batch-center` に `user-sync-verify` ジョブを追加し、`owl-user-sync --verify` の出力（実際の `/etc/passwd` + `authorized_keys`）と Core の `User` 射影を突合
- 不一致があれば `UserOsDriftDetected` イベントを記録し、運用者に通知（具体的な通知経路は cron_batch.md の既存ログ/アラート機構に委ねる）
- **自動修復はしない。** ドリフトは人間の確認を要する事象として扱う（40分ハングの教訓と同じく、検出したら止めて知らせる方を優先する）。

## 5. 状態遷移まとめ

```
            CreateUser
                │
                ▼
            Pending ──UserOsSyncFailed──▶ Pending（再試行 or 人間が介入）
                │
        UserOsSyncSucceeded
                ▼
             Active ◀──────────ReactivateUser──────────┐
                │                                       │
          SuspendUser                                   │
                ▼                                       │
            Suspended ─────────────────────────────────┘
                │
           RemoveUser（Active からも直接可）
                ▼
             Removed（終端）
```

## 6. 既存コードへの接続点（実装時の参照）

- `src/Core/Domain/User.hs` 新規、CLAUDE.md の Recipe に従い `Core/Command.hs` / `Core/Event.hs` / `Core/Decide.hs` / `Core/Evolve.hs` に分岐追加
- `Core.Domain.OrgPermission.PermScope` はそのまま再利用（`User` が持つ）
- `Shell/Interpreters/UserContext.hs` の `runUserCtxPg` 呼び出し元を、固定文字列から §4.1 の検証済み `UserId` に置き換える
- 新規 `Shell/Interpreters/UserOsSync.hs`（§3 の effect）
- `infra/vm-ap/setup.sh` の `add-owl-operator`/`add-owl-maintainer` を `owl-user-sync` 配置に置き換える（実装タスク、本書はその設計確定のみ）

## 7. 決定事項

以下は当初「未決事項」としていたが、運用者が少数（＝関係者全員の動きを把握できる規模）であることを前提に、シンプルさを優先して確定する。将来チームが拡大した場合は再検討する。

- **Admin 役割の発行経路**：§2 で確定済み。`owl-config.toml` の `[user] root_admin_username` に指定した専用 OS アカウントを `usermod -G wheel` で作り、**そのユーザー名で SSH 確立した時にのみ** owlv 側が自動的に `Admin`・`Active` な `User` を生成する。これ以外の経路で Admin は生まれない。
- **ドリフト検知・`pkill` 失敗の通知先**：専用のアラート基盤は新設しない。cron_batch.md と同じ仕組み（`/var/log/owlv/` への記録 + ジョブが非ゼロ終了することで OpenBSD cron の標準動作である root 宛メールに乗せる）に統合する。少数運用ではログ監視と cron メールの目視で十分であり、新規の通知経路は過剰投資と判断する。
- **パスワード関連イベントの保存先分離**：分離しない。会計イベントと同じイベントストアにそのまま記録する。`userPasswordHash` は SSH 認証の代替ではなくアプリ内ステップアップ確認専用（§2.3）であり価値の低い標的のため、別ストアを設けるコストに見合わない。Argon2id パラメータ更新時に旧イベントが追従しない点は許容する。
- **`pkill -u` の射程**：意図的に同一 OS ユーザー名の全セッションを対象とする。`Suspended`/`Removed` は「この身元によるアクセスを今すぐ全部止める」ことが目的であり、ForceCommand 経由か生シェルかという経路の違いで扱いを分けない。Operator/Maintainer の区別なく一括切断する。
