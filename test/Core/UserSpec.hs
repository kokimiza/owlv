module Core.UserSpec (tests) where

import Test.Tasty
import Test.Tasty.HUnit

import Data.Map.Strict qualified as Map
import Data.Text qualified as T

import Core.Command (Command (..))
import Core.Decide (decide)
import Core.Domain.User
  ( OsUid (..)
  , Role (..)
  , SshPubKey (..)
  , UserId
  , firstOsUid
  , mkSshPubKey
  , mkUserId
  , userStatus
  )
import Core.Error (DomainError (..))
import Core.Event (Event (..))
import Core.Evolve (evolve)
import Core.State (AppBook (..), UserBook (..), initialAppBook)

-- ── Helpers ─────────────────────────────────────────────────────────────────

mkId :: String -> UserId
mkId s = case mkUserId (T.pack s) of
  Right u -> u
  Left e -> error ("bad test UserId: " <> T.unpack e)

key :: String -> SshPubKey
key s = case mkSshPubKey (T.pack s) of
  Right k -> k
  Left e -> error ("bad test SshPubKey: " <> T.unpack e)

admin1, admin2, alice, bob :: UserId
admin1 = mkId "admin1"
admin2 = mkId "admin2"
alice = mkId "alice"
bob = mkId "bob"

-- | ブートストラップで admin1 を Active な Admin にした AppBook。
bookWithAdmin :: AppBook
bookWithAdmin =
  foldl'
    evolve
    initialAppBook
    [ UserCreated admin1 firstOsUid "Admin One" Admin []
    , UserOsSyncSucceeded admin1
    ]

-- ── Test tree ────────────────────────────────────────────────────────────────

tests :: TestTree
tests =
  testGroup
    "Core.User"
    [ testGroup "Bootstrap" bootstrapTests
    , testGroup "CreateUser" createTests
    , testGroup "RoleEscalation" roleEscalationTests
    , testGroup "Lifecycle" lifecycleTests
    , testGroup "SshKey" sshKeyTests
    , testGroup "SelfOrAdmin" selfOrAdminTests
    , testGroup "Scope" scopeTests
    , testGroup "Evolve" evolveTests
    ]

-- ── Bootstrap (.claude/user.md §2/§7) ───────────────────────────────────────

bootstrapTests :: [TestTree]
bootstrapTests =
  [ testCase "Active な Admin が0人なら actor 検証を免除して作成できる" $
      decide initialAppBook (CreateUser admin1 admin1 "Admin One" Admin [])
        @?= Right [UserCreated admin1 firstOsUid "Admin One" Admin []]
  , testCase "Active な Admin が既にいれば actor を要求する" $
      case decide bookWithAdmin (CreateUser bob bob "Bob" Operator []) of
        Left (ActorNotAuthorized actor) -> actor @?= bob
        other -> assertFailure ("expected ActorNotAuthorized, got: " <> show other)
  ]

-- ── CreateUser ───────────────────────────────────────────────────────────────

createTests :: [TestTree]
createTests =
  [ testCase "Admin actor による新規作成は成功する" $
      decide bookWithAdmin (CreateUser admin1 alice "Alice" Operator [])
        @?= Right [UserCreated alice (ubNextUid (appUsers bookWithAdmin)) "Alice" Operator []]
  , testCase "重複 UserId は DuplicateUserId" $
      let book = foldl' evolve bookWithAdmin [UserCreated alice firstOsUid "Alice" Operator []]
      in case decide book (CreateUser admin1 alice "Alice2" Operator []) of
           Left (DuplicateUserId target) -> target @?= alice
           other -> assertFailure ("expected DuplicateUserId, got: " <> show other)
  ]

-- ── Role escalation: dual control (.claude/user.md §2) ──────────────────────

roleEscalationTests :: [TestTree]
roleEscalationTests =
  let book0 = foldl' evolve bookWithAdmin [UserCreated alice firstOsUid "Alice" Operator []]
  in [ testCase "ChangeUserRole で直接 Admin にはできない" $
         case decide book0 (ChangeUserRole admin1 alice Admin) of
           Left (DirectAdminEscalationForbidden target) -> target @?= alice
           other -> assertFailure ("expected DirectAdminEscalationForbidden, got: " <> show other)
     , testCase "提案なしの承認は NoPendingRoleEscalation" $
         case decide book0 (ApproveRoleEscalation admin1 alice) of
           Left (NoPendingRoleEscalation target) -> target @?= alice
           other -> assertFailure ("expected NoPendingRoleEscalation, got: " <> show other)
     , testCase "提案者自身による承認は SelfApprovalNotAllowed" $
         let book1 = foldl' evolve book0 [UserRoleEscalationProposed admin1 alice]
         in case decide book1 (ApproveRoleEscalation admin1 alice) of
              Left (SelfApprovalNotAllowed target) -> target @?= alice
              other -> assertFailure ("expected SelfApprovalNotAllowed, got: " <> show other)
     , testCase "別の Admin による承認で Admin へ昇格する" $
         let book1 =
               foldl'
                 evolve
                 book0
                 [ UserCreated admin2 firstOsUid "Admin Two" Admin []
                 , UserOsSyncSucceeded admin2
                 , UserRoleEscalationProposed admin1 alice
                 ]
         in decide book1 (ApproveRoleEscalation admin2 alice) @?= Right [UserRoleChanged alice Admin]
     ]

-- ── Lifecycle: Suspend/Reactivate/Remove (.claude/user.md §2.1) ──────────────

lifecycleTests :: [TestTree]
lifecycleTests =
  let book0 = foldl' evolve bookWithAdmin [UserCreated alice firstOsUid "Alice" Operator []]
  in [ testCase "Suspend は成功する" $
         decide book0 (SuspendUser admin1 alice) @?= Right [UserSuspended alice]
     , testCase "Removed からの操作はすべて UserAlreadyRemoved" $
         let book1 = foldl' evolve book0 [UserRemoved alice]
         in case decide book1 (SuspendUser admin1 alice) of
              Left (UserAlreadyRemoved target) -> target @?= alice
              other -> assertFailure ("expected UserAlreadyRemoved, got: " <> show other)
     , testCase "存在しないユーザーは UserNotFound" $
         case decide bookWithAdmin (SuspendUser admin1 bob) of
           Left (UserNotFound target) -> target @?= bob
           other -> assertFailure ("expected UserNotFound, got: " <> show other)
     ]

-- ── SSH 公開鍵 (.claude/user.md §2.1: オプション禁止・鍵共有禁止) ──────────────

sshKeyTests :: [TestTree]
sshKeyTests =
  let book0 = foldl' evolve bookWithAdmin [UserCreated alice firstOsUid "Alice" Operator []]
  in [ testCase "オプション付き鍵文字列は mkSshPubKey で拒否される" $
         case mkSshPubKey (T.pack "command=\"/bin/sh\" ssh-ed25519 AAAA") of
           Left _ -> pure ()
           Right _ -> assertFailure "expected rejection of option-prefixed key"
     , testCase "正常な鍵の登録は成功する" $
         decide book0 (RegisterUserSshKey alice alice (key "ssh-ed25519 AAAAalice"))
           @?= Right [UserSshKeyRegistered alice (key "ssh-ed25519 AAAAalice")]
     , testCase "他ユーザーに登録済みの鍵は DuplicateSshPubKey" $
         let book1 =
               foldl'
                 evolve
                 book0
                 [ UserCreated bob firstOsUid "Bob" Operator []
                 , UserSshKeyRegistered bob (key "ssh-ed25519 AAAAshared")
                 ]
         in case decide book1 (RegisterUserSshKey alice alice (key "ssh-ed25519 AAAAshared")) of
              Left (DuplicateSshPubKey _) -> pure ()
              other -> assertFailure ("expected DuplicateSshPubKey, got: " <> show other)
     ]

-- ── 自己管理操作: 本人または Admin (.claude/user.md §2.2) ────────────────────

selfOrAdminTests :: [TestTree]
selfOrAdminTests =
  let book0 =
        foldl'
          evolve
          bookWithAdmin
          [ UserCreated alice firstOsUid "Alice" Operator []
          , UserCreated bob firstOsUid "Bob" Operator []
          ]
  in [ testCase "本人によるパスワード変更は成功する" $
         decide book0 (SetUserPasswordHash alice alice "hash")
           @?= Right [UserPasswordChanged alice "hash"]
     , testCase "他人（非Admin）によるパスワード変更は NotSelfOrAdmin" $
         case decide book0 (SetUserPasswordHash bob alice "hash") of
           Left (NotSelfOrAdmin actor target) -> (actor, target) @?= (bob, alice)
           other -> assertFailure ("expected NotSelfOrAdmin, got: " <> show other)
     , testCase "Admin によるパスワード変更は成功する" $
         decide book0 (SetUserPasswordHash admin1 alice "hash")
           @?= Right [UserPasswordChanged alice "hash"]
     ]

-- ── 画面スコープ (.claude/user.md §2) ────────────────────────────────────────

scopeTests :: [TestTree]
scopeTests =
  let book0 = foldl' evolve bookWithAdmin [UserCreated alice firstOsUid "Alice" Operator []]
  in [ testCase "スコープ付与は成功する" $
         decide book0 (GrantUserScope admin1 alice "journal")
           @?= Right [UserScopeGranted alice "journal"]
     , testCase "重複付与は UserScopeAlreadyGranted" $
         let book1 = foldl' evolve book0 [UserScopeGranted alice "journal"]
         in case decide book1 (GrantUserScope admin1 alice "journal") of
              Left (UserScopeAlreadyGranted _ _) -> pure ()
              other -> assertFailure ("expected UserScopeAlreadyGranted, got: " <> show other)
     , testCase "存在しないスコープの剥奪は UserScopeNotFound" $
         case decide book0 (RevokeUserScope admin1 alice "journal") of
           Left (UserScopeNotFound _ _) -> pure ()
           other -> assertFailure ("expected UserScopeNotFound, got: " <> show other)
     ]

-- ── evolve の状態機械 (.claude/user.md §2.1: Active は同期成功でのみ到達) ────

evolveTests :: [TestTree]
evolveTests =
  [ testCase "UserCreated 直後は Pending" $
      let book = evolve initialAppBook (UserCreated alice firstOsUid "Alice" Operator [])
      in lookupStatus book alice @?= Just "Pending"
  , testCase "UserOsSyncSucceeded で Active になる" $
      let book =
            foldl'
              evolve
              initialAppBook
              [UserCreated alice firstOsUid "Alice" Operator [], UserOsSyncSucceeded alice]
      in lookupStatus book alice @?= Just "Active"
  , testCase "UserReactivated は Active ではなく Pending に戻す（再同期必須）" $
      let book =
            foldl'
              evolve
              initialAppBook
              [ UserCreated alice firstOsUid "Alice" Operator []
              , UserOsSyncSucceeded alice
              , UserSuspended alice
              , UserReactivated alice
              ]
      in lookupStatus book alice @?= Just "Pending"
  , testCase "ubNextUid は UserCreated ごとに単調増加する（UID 再利用なし）" $
      let book =
            foldl'
              evolve
              initialAppBook
              [ UserCreated alice firstOsUid "Alice" Operator []
              , UserRemoved alice
              ]
      in ubNextUid (appUsers book) @?= succUid firstOsUid
  ]
 where
  lookupStatus book u = fmap (show . userStatus) (Map.lookup u (users (appUsers book)))
  succUid (OsUid n) = OsUid (n + 1)
