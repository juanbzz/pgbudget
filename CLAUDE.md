# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

pgbudget is a PostgreSQL budgeting engine. It uses double-entry accounting internally, but the API speaks budgeting language — income, expenses, categories, transfers. The double-entry mechanics are invisible to consumers.

**Identity:** Engine, not app. No payees, tags, goals, auth, or UI concerns. The `metadata` jsonb column is the escape hatch for consumer apps.

**Immutability:** Transactions are never edited or deleted. Corrections and voids create reversals. The books are always provably correct.

## Development Commands

### Database Migrations (using Goose)
```bash
task migrate:up          # Run all pending migrations
task migrate:up-one      # Run one migration
task migrate:down        # Rollback last migration
task migrate:drop        # Drop all migrations
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

### Three-schema design
- **`data`**: Tables, constraints, RLS policies. Accounting vocabulary is fine here.
- **`utils`**: Internal business logic. Accounting vocabulary (debit/credit, asset/liability). `SECURITY DEFINER`.
- **`api`**: Public interface. **Budgeting vocabulary only** (budget, income, expense, category, transfer, void, correct).

### API vocabulary mapping

| API (public) | Internal (utils/data) |
|---|---|
| Budget | Ledger |
| `bank`, `credit_card`, `cash` | `asset`, `liability` |
| Category | Equity account |
| `record_income` | inflow transaction |
| `record_expense` | outflow transaction |
| `budget_money` | assign_to_category |
| `move_money` | category-to-category transfer |
| `transfer` | account-to-account transfer |
| `void` | delete_transaction (reversal) |
| `correct` | correct_transaction (reversal + new) |

### New API functions (v0.1.0 in progress)
```sql
api.create_budget(name, description?)              -- returns uuid
api.add_account(budget, name, type, description?)  -- type: bank/credit_card/cash/asset/liability
api.add_category(budget, name)                     -- existing, unchanged
api.record_income(budget, account, amount, desc, date?)
api.record_expense(budget, account, amount, category?, desc, date?)
api.budget_money(budget, category, amount, desc?, date?)
api.move_money(budget, from_cat, to_cat, amount, desc?, date?)
api.transfer(budget, from_acct, to_acct, amount, desc?, date?)  -- not yet implemented
api.void(transaction, reason?)                                    -- not yet implemented
api.correct(transaction, ...changed_fields, reason?)              -- not yet implemented
```

### Legacy API (still works, will be deprecated)
```sql
INSERT INTO api.ledgers (name) VALUES (...)
INSERT INTO api.accounts (ledger_uuid, name, type) VALUES (...)
INSERT INTO api.transactions (...)  -- via INSTEAD OF INSERT trigger
api.add_transaction(ledger, date, desc, type, amount, account, category?)
api.assign_to_category(ledger, date, desc, amount, category)
api.correct_transaction(...)
api.delete_transaction(...)
```

## Development Conventions

### PostgreSQL code style
- Write SQL in lowercase
- Add comments above each query step
- `bigint generated always as identity` for primary keys
- Table-level constraints named `{table}_{column}_{constraint_type}`
- Triggers named `{table}_{purpose}_tg`
- Follow conventions from `/Users/juanolvera/sync/proj/2025-04-24-conventions/src/conventions/postgres/`

### Function patterns
- **New API functions**: Simple, return UUID (text). Accept budgeting vocabulary.
- **Utils functions**: Accept text UUIDs, handle internal logic, return int IDs.
- **Each step is one commit**: migration + tests. All existing tests stay green.

### Testing
- Uses testcontainers (Docker via Colima) for PostgreSQL integration testing
- Each test function gets its own connection and user context
- Test user context: `set_config('app.current_user_id', 'user_id', false)`
- Tests are the reference documentation for how to use the API

## Current plan

See `nogit_docs/V1_PLAN.md` for the full v0.1.0 plan.

Steps 1-8 are complete. Remaining: `api.transfer()`, `api.void()`, `api.correct()`, reporting renames, `api.delete_budget()`, deprecation wrappers, test migration, release.

## File structure

- `migrations/` — Goose SQL migrations (chronological)
- `releases/` — Version snapshots (schema.sql, upgrade scripts)
- `scripts/` — Release and install scripts
- `nogit_docs/` — Planning docs, not tracked in releases
- `main_test.go` — Integration tests
- `testutils/pgcontainer/` — PostgreSQL container setup
