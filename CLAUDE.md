# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
cabal build                                   # build
cabal run owlv                                # run TUI
cabal repl                                    # REPL
cabal test --test-options='-p "<pattern>"'    # single test — prefer this over the full suite
cabal test                                    # full suite (run before commit only)
fourmolu -i $(git ls-files '*.hs')            # format
hlint app src test                            # lint
cabal build --ghc-options="-Werror"           # CI-equivalent build
```

## Project overview

`owlv` is an IFRS-compliant personal-finance TUI: Haskell + brick, Event Sourcing + CQRS.
Event store: SQLite (append-only). Read model: RocksDB.

The domain specification is [doc/ifrs_standard.md](doc/ifrs_standard.md) (Japanese, v2.0) — the single authoritative source for all accounting logic, including the nine-phase closing pipeline (§1.2). Read the relevant section before implementing any accounting or closing-process feature. Do not duplicate spec content into this file or into docs; reference it by section number.

## Architecture: FCIS (Functional Core, Imperative Shell)

Dependency direction is one-way and absolute: `Core ← Shell`. FCIS draws one line — pure vs. effectful — not a stack of layers, so there is no separate `UseCases/` folder (unlike classic Clean Architecture, which has an interactor layer between domain and infrastructure).

- `src/Core/` — pure. MUST NOT import IO, brick, database, clock, random, or anything effectful.
- `src/Shell/` — the only place IO is allowed: SQLite event store, RocksDB projector, brick TUI, clock, and the single generic command executor (load events → fold `evolve` → `decide` → append events). Use-case-shaped orchestration (load data → call Core → persist) lives here, as plain functions that call into Core — not as a separate layer or typeclass.
- `app/Main.hs` — config, wiring, startup only.

### Recipe for adding a feature (follow exactly)

1. Add a constructor to `Core/Command.hs`
2. Add a constructor to `Core/Event.hs`
3. Add a branch to `decide` in `Core/Decide.hs` — domain invariants live here
4. Add a branch to `evolve` in `Core/Evolve.hs`
5. Shell stays untouched by default. If you believe Shell must change, stop and explain why before editing.
6. Add property tests for every new decide/evolve branch (debit = credit, fold determinism, serialization roundtrip).

Shell orchestration must load all required data up front (sandwich pattern) so the Core calls in between stay pure. Do not introduce effect interfaces, free monads, or repository typeclasses to work around this — widen the function's input instead.

## Domain invariants (MUST)

- Money is `Core.Domain.Money` (Decimal-based). `Double` is banned everywhere, including tests.
- The event store is append-only. Never write code that mutates or deletes recorded events.
- Every journal entry carries a 仕訳行為区分 (新規起票/取消/反対/追加/再分類/洗替/見積変更). Corrections are new entries referencing the original — never in-place edits. (spec §2.1.1)
- 帳簿価額 (carrying amount) sits between measurement and presentation; the Statements layer maps it to FS line items and must never alter it. (spec §2.3, §4.9)
- ECL: all stages discount at the **original EIR**; credit-adjusted EIR applies to POCI assets only. The simplified approach (lifetime ECL, no staging) is mandatory for trade receivables without a significant financing component. (spec §4.7.5–4.7.10)
- When implementing measurement logic, cite the spec section in a comment, e.g. `-- 規程 4.7.9.2`.
- If an IFRS interpretation is ambiguous, ask — do not guess. Propose a spec amendment instead of silently diverging from it.

## Forbidden

- `unsafePerformIO`; partial functions (`head`, `fromJust`, incomplete patterns)
- Effectful imports inside `Core/`
- Accounting logic that contradicts the spec

## Toolchain

- Language edition: **GHC2024** — requires GHC >= 9.10 (`base ^>= 4.20`).
- `-Wall` on all modules; CI builds with `-Werror`.
- New dependencies go in `build-depends` in `owlv.cabal`. Justify each addition in the PR/commit message.

## Domain reference map

[doc/ifrs_standard.md](doc/ifrs_standard.md):

- §2 — Financial information infrastructure (journal classifications, ledgers, carrying amount, fixed assets)
- §3 — Materiality thresholds and risk tiers
- §4 — Closing process (§4.3 IFRS 15 / §4.7 ECL, FX, inventory, employee benefits, taxes / §4.10 subsequent events / §4.11 going concern)
- §5 — Judgment log requirements
- §6 — Management accounting and KPIs
- §7 — Reproducibility (versioning, parameter snapshots, hash-based tamper detection)