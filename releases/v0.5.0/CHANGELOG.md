# pgbudget v0.5.0 Release Notes

Released: 2026-04-23

## Summary

Architectural reset. The `api` and `budget` schemas from v0.4.0 have been removed. v0.5.0 ships a clean, TigerBeetle-inspired generic double-entry ledger engine. The budget application layer is **not yet built** and will ship in v1.0.0.

This is a **breaking release** with no upgrade path from v0.4.0 — the schema, API surface, and semantics are all different. Fresh installs only.

## Added

### `ledger` schema — generic double-entry engine (18 functions)

- **Setup**: `create_ledger`, `create_account`, `close_account`, `delete_ledger`
- **Posting**: `post_transaction`, `post_transactions` (batch), `post_linked` (multi-leg)
- **Two-phase transfers**: `reserve`, `commit` (partial commits supported), `release`, `expire_pending`
- **Corrections**: `void`, `correct` (immutable — create reversals, never UPDATE)
- **Queries**: `get_balance`, `get_balances`, `get_accounts`, `get_history`, `rebuild_balances`

### Engine properties

- **No account types.** Accounts are containers with raw `debits_total` / `credits_total` counters. The application layer decides semantics.
- **Raw counters, not signed balances.** The engine never computes `debits - credits`.
- **Immutable transactions.** INSERT-only. Void/correct create reversal transactions.
- **Balance constraints.** Per-account `debits_must_not_exceed_credits` / `credits_must_not_exceed_debits` flags enforced in the checked write path.
- **Idempotency.** Optional `idempotency_key` per transaction with unique_violation race handling.
- **Account closing.** Closed accounts reject new posts/reserves/commits/corrects but still allow void/release so pending holds can unwind.
- **Linked transfers.** `link_id` groups multi-leg transactions through a caller-provided clearing account (`visibility = 'internal'`). `get_history` resolves the true counterparty automatically.
- **RLS multi-tenancy.** `user_data` column + policies on every table in `data.*`.

## Removed

- `api` schema (all functions)
- `budget` / category / group vocabulary
- Account `type` and `internal_type` columns
- Trigger-driven balance maintenance (replaced by explicit writes in `ledger.post_transaction`)
- Old balance system (superseded by `data.balances` append-only table + `data.accounts` counters)

## Migration history reset

The 60 migrations from v0.1.0 through v0.4.0 have been collapsed into a single initial migration (`migrations/00001_initial_schema.sql`). Old migrations are preserved in git history. Fresh installs run one migration; upgrades from v0.4.0 require a manual data port (not provided).

## Tooling

- `releases/v0.5.0/schema.sql` — complete schema for fresh installs
- `releases/v0.5.0/install.sh` — installer wrapper
- `utils.metadata` — version stamp table (`key = 'version'`)

## What's next (v1.0.0)

The `budget` schema will sit on top of `ledger`, translating budgeting vocabulary (income, categories, expenses, transfers) into ledger calls and computing signed balances based on account role. Tracked by beads tickets `pgbudget-atf`, `pgbudget-qoe`, `pgbudget-a09`, `pgbudget-cgd`.
