# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pgbudget is two things in one PostgreSQL database:

1. **`ledger` schema** — a generic double-entry accounting engine (TigerBeetle-inspired)
2. **`budget` schema** — a budgeting application layer (not yet built, planned)

The ledger layer is complete and handles accounts, transactions, balances, corrections, two-phase transfers, batch inserts, idempotency, and per-account balance constraints. It knows nothing about budgeting.

The budget layer will sit on top, translating budgeting vocabulary (income, expenses, categories) into ledger operations (debits, credits, accounts).

## Development Commands

### Database Migrations (using Goose)
```bash
task migrate:up          # Run all pending migrations
task migrate:up-one      # Run one migration
task migrate:down        # Rollback last migration
task migrate:status      # Show migration status
task migrate:new -- name # Create new migration
```

### Testing
```bash
go test -v               # Run all tests
go test -v -run TestName # Run specific test
```

Tests require Docker via Colima. The `.envrc` sets `DOCKER_HOST` and `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE` for testcontainers.

## Architecture

### Four-schema design
- **`data`**: Tables, constraints, RLS policies, indexes
- **`utils`**: Internal helpers (validation, user context, fast/checked write paths)
- **`ledger`**: Generic double-entry API (accounts, transactions, balances)
- **`budget`**: Budgeting application layer (not yet built — calls `ledger.*`)
- **`api`**: Legacy functions (will be removed)

### Ledger API (complete — 18 functions)

```sql
-- setup
ledger.create_ledger(name, description?)       -- auto-creates internal 'clearing' account
ledger.create_account(ledger, name, type, description?,
    debits_must_not_exceed_credits?, credits_must_not_exceed_debits?)
ledger.close_account(account)                  -- permanent, rejects new transactions
ledger.delete_ledger(ledger)                   -- CASCADE with cleanup

-- core transaction primitive
ledger.post_transaction(ledger, debit, credit, amount, date?, description?, idempotency_key?)
ledger.post_transactions(ledger, jsonb_array)  -- batch
ledger.post_linked(ledger, jsonb_array)        -- multi-leg with clearing account

-- two-phase transfers
ledger.reserve(ledger, debit, credit, amount, timeout_seconds?, date?, description?, idempotency_key?)
ledger.commit(transaction, amount?)            -- partial commits supported
ledger.release(transaction)                    -- void pending hold
ledger.expire_pending()                        -- cleanup timed-out holds

-- corrections (immutable — creates reversals)
ledger.void(transaction, reason?)              -- allowed on closed accounts
ledger.correct(transaction, debit?, credit?, amount?, description?, date?, reason?)

-- queries
ledger.get_balance(account)                    -- reads from account counters
ledger.get_balances(ledger)                    -- all accounts in ledger
ledger.get_accounts(ledger, include_internal?) -- account list with visibility filter
ledger.get_history(account)                    -- resolves counterparty through clearing
ledger.rebuild_balances(ledger)                -- data repair
```

### Key design decisions

- **No triggers for balances.** `ledger.post_transaction()` does INSERT + UPDATE counters + INSERT history in one function. Two internal paths: `utils.post_transaction_fast()` (no constraint checks) and `utils.post_transaction_checked()` (conditional UPDATE with constraint enforcement).
- **Immutable transactions.** INSERT only. Void/correct create reversals. No UPDATE/DELETE on transaction rows.
- **Balance constraints.** Per-account flags: `debits_must_not_exceed_credits` and `credits_must_not_exceed_debits`. Checked path uses conditional UPDATE. Pending holds count against constraints.
- **Pending state in `data.pending` table.** Not counters on accounts. Rows exist while hold is active, deleted on resolve. No drift.
- **Idempotency.** Optional `idempotency_key` on transactions. Partial unique index. Race condition handled via unique_violation catch.
- **Account closing.** `is_closed` flag. Rejects post_transaction, reserve, commit, correct. Allows void and release (must be able to unwind).
- **Linked transfers.** `link_id` (bigint) groups multi-leg transactions. Internal `clearing` account (visibility='internal') as intermediary. `get_history()` resolves counterparty through clearing automatically.
- **Account visibility.** `visibility` column: `'standard'` (user-facing) or `'internal'` (system). `get_accounts()` hides internal by default.

### Balance system

- **Current balance:** `debits_total` / `credits_total` on `data.accounts` (atomic UPDATE, one row read)
- **Historical balance:** `data.balances` table (append-only, one row per account per transaction)
- **Pending holds:** `data.pending` table (active holds only, deleted on resolve)
- **Balance = `debits_total - credits_total`** (asset_like) or **`credits_total - debits_total`** (liability_like/equity)
- **Pending refactor:** Remove `internal_type`, use `type` for balance direction

## Development Conventions

### PostgreSQL code style
- Write SQL in lowercase
- Add comments above each query step
- `bigint generated always as identity` for primary keys
- Table-level constraints named `{table}_{column}_{constraint_type}`
- Triggers named `{table}_{purpose}_tg`
- Follow conventions from `/Users/juanolvera/sync/proj/2025-04-24-conventions/src/conventions/postgres/`

### Function patterns
- **`ledger.*` functions**: Generic double-entry. Take debit/credit account UUIDs directly. No budgeting vocabulary.
- **`budget.*` functions** (planned): Budgeting vocabulary. Call `ledger.*` internally.
- **`utils.*` functions**: Internal helpers. Called by `ledger.*`. Not exposed to consumers.
- **Each step is one commit**: migration + tests. All existing tests stay green.

### Testing
- Uses testcontainers (Docker via Colima) for PostgreSQL integration testing
- Each test function gets its own connection and user context
- Test user context: `set_config('app.current_user_id', 'user_id', false)`

## Planning docs

- `nogit_docs/ARCHITECTURE_V2.md` — full architecture (ledger + budget layers, scale considerations)
- `nogit_docs/TIGERBEETLE_GAPS.md` — feature comparison with TigerBeetle
- `nogit_docs/TWO_PHASE_PLAN.md` — two-phase transfer design
- `nogit_docs/BUDGET_SCHEMA_PLAN.md` — budget layer plan
- `nogit_docs/REARCHITECTURE_PLAN.md` — migration steps

## File structure

- `migrations/` — Goose SQL migrations (chronological)
- `releases/` — Version snapshots (schema.sql, upgrade scripts)
- `scripts/` — Release and install scripts
- `nogit_docs/` — Planning docs, not tracked in releases
- `main_test.go` — Integration tests
- `testutils/pgcontainer/` — PostgreSQL container setup
