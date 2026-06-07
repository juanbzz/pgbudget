<div align="center">
  <img src="pgbudget.png" alt="pgbudget" width="200"/>
</div>

# pgbudget

A generic double-entry accounting engine in PostgreSQL, inspired by
[TigerBeetle](https://tigerbeetle.com/), with a zero-sum budgeting layer
built on top.

## What it is

pgbudget is two things in one PostgreSQL database:

1. **`ledger` schema**: a generic double-entry accounting engine.
   Accounts have no type; they are just containers with debit/credit
   counters and optional balance constraints. The engine moves numbers
   between accounts and returns raw counters. It knows nothing about
   budgeting.
2. **`budget` schema**: a zero-sum budgeting application layer (similar
   to YNAB) that translates budgeting vocabulary (income, expenses,
   categories) into ledger operations. Planned, not yet built.

> **Status:** The ledger engine is complete and fully tested. The budget
> layer is the next milestone.

## Design

The ledger follows TigerBeetle's model rather than traditional
application-coupled accounting:

- **No account types.** Accounts are containers with `debits_total` and
  `credits_total` counters. Whether an account is an "asset" or a
  "liability" is the application layer's interpretation, not the
  engine's.
- **Raw counters, not signed balances.** `get_balance()` returns
  `(debits_total, credits_total)`. The caller computes the signed
  balance based on what it knows the account means (e.g.
  `debits - credits` for assets, `credits - debits` for liabilities).
- **Immutable transactions.** Rows are INSERT-only. Mistakes are fixed
  by `void` and `correct`, which create reversing transactions, never by
  UPDATE or DELETE.
- **Multi-tenant by row-level security.** Every row carries a
  `user_data` column; RLS isolates each tenant. What `user_data`
  represents (a user, an org, a merchant) is the application's choice.
- **Balance constraints.** Optional per-account constraints
  (`debits_must_not_exceed_credits`, `credits_must_not_exceed_debits`),
  enforced on the checked write path; pending holds count against them.
- **Flexible posting.** Single and batch transaction posting, plus
  linked multi-leg transfers through a caller-provided clearing account.
- **Two-phase transfers.** `reserve` then `commit`/`release`, with
  timeouts and partial commits.
- **Idempotency.** Optional idempotency keys on transactions.
- **Account lifecycle.** Permanent closing that rejects new activity but
  allows unwinding existing state, plus `standard` vs `internal` account
  visibility.
- **App-defined `code` field.** A smallint on accounts and transactions
  for categorization; the engine stores and indexes it but assigns no
  meaning.
- **Balance history.** Append-only history alongside atomic current
  counters.

## Requirements

- PostgreSQL 14 or higher
- [Goose](https://github.com/pressly/goose) for database migrations
- Docker, to run the test suite

## Setup

1. Create a PostgreSQL database.
2. Run migrations:

```bash
goose -dir migrations postgres "your-connection-string" up
```

3. Set the tenant context at the start of each session:

```sql
select set_config('app.current_user_id', 'your-tenant-id', false);
```

All RLS policies filter on `utils.get_user()`, which reads
`app.current_user_id` (falling back to the database role if unset).

## Amounts

All monetary amounts are stored as `bigint` in the smallest currency
unit (e.g. cents). $10.00 is `1000`.

## Quick start

```sql
-- set the tenant context for this session
select set_config('app.current_user_id', 'demo-user', false);

-- create a ledger
select ledger.create_ledger('Personal') as ledger_uuid;  -- e.g. 'd3pOOf6t'

-- create two accounts in the ledger
select ledger.create_account('d3pOOf6t', 'Checking') as checking_uuid; -- 'aK9sLp0Q'
select ledger.create_account('d3pOOf6t', 'Rent')     as rent_uuid;     -- 'mN8xPqR3'

-- post a transfer: debit Rent, credit Checking, $1,200
select ledger.post_transaction(
    'd3pOOf6t',          -- ledger
    'mN8xPqR3',          -- debit account
    'aK9sLp0Q',          -- credit account
    120000,              -- amount in cents
    current_date,        -- date
    'April rent'         -- description
);

-- read raw counters; the app decides how to sign them
select * from ledger.get_balance('aK9sLp0Q');
--  debits_total | credits_total
-- --------------+---------------
--             0 |        120000
```

## Ledger API

All amounts are `bigint` (smallest currency unit). Queries return raw
counters, not signed balances.

### Setup

```sql
ledger.create_ledger(name, description?)
ledger.create_account(ledger, name, description?,
    debits_must_not_exceed_credits?, credits_must_not_exceed_debits?, code?)
ledger.close_account(account)         -- permanent; rejects new transactions
ledger.delete_ledger(ledger)          -- CASCADE with cleanup
```

### Posting transactions

```sql
ledger.post_transaction(ledger, debit, credit, amount,
    date?, description?, idempotency_key?)
ledger.post_transactions(ledger, jsonb_array)   -- batch, all-or-nothing
ledger.post_linked(ledger, jsonb_array)         -- multi-leg via clearing account
```

### Two-phase transfers

```sql
ledger.reserve(ledger, debit, credit, amount,
    timeout_seconds?, date?, description?, idempotency_key?)
ledger.commit(transaction, amount?)   -- partial commits supported
ledger.release(transaction)           -- void a pending hold
ledger.expire_pending()               -- clean up timed-out holds
```

### Corrections (immutable)

```sql
ledger.void(transaction, reason?)     -- full reversal; allowed on closed accounts
ledger.correct(transaction, debit?, credit?, amount?, description?, date?, reason?)
```

### Queries

```sql
ledger.get_balance(account)                    -- (debits_total, credits_total)
ledger.get_balances(ledger)                    -- per-account counters
ledger.get_accounts(ledger, include_internal?) -- account list with visibility filter
ledger.get_history(account)                    -- counters per transaction, resolves counterparty
ledger.rebuild_balances(ledger)                -- data repair
```

## Account closing

Accounts can be permanently closed with `ledger.close_account()`. A
closed account rejects new activity but allows you to unwind existing
state.

| Operation | Allowed? | Why |
|---|---|---|
| `ledger.post_transaction()` | No | No new transactions |
| `ledger.post_transactions()` | No | Batch rejected if any leg hits a closed account |
| `ledger.reserve()` | No | No new holds |
| `ledger.commit()` | No | Can't settle on a frozen account |
| `ledger.release()` | **Yes** | Must be able to release pending holds |
| `ledger.void()` | **Yes** | Must be able to reverse mistakes |
| `ledger.correct()` | No | The corrected transaction is a new transaction |
| `ledger.get_balance()` | **Yes** | Read-only |
| `ledger.get_history()` | **Yes** | Read-only |

Closing is permanent; there is no reopen. If you need the account again,
create a new one.

## Architecture

The database uses a layered schema design:

- **`data`**: tables, constraints, RLS policies, indexes
- **`utils`**: internal helpers (tenant context, fast/checked write paths)
- **`ledger`**: the generic double-entry engine (public API)
- **`budget`**: the budgeting application layer (planned; will call
  `ledger.*` internally)

The `ledger` schema is the complete engine. The `budget` schema will sit
on top, assigning meaning to accounts (asset, liability, equity),
computing signed balances, and exposing budgeting vocabulary, all in
terms of ledger operations.

## Testing

Tests are Go integration tests that spin up a real PostgreSQL instance
with testcontainers, so a running Docker daemon is required.

```bash
go test -v               # run all tests
go test -v -run TestName # run a specific test
```

## License

Licensed under the GNU Affero General Public License v3.0 (AGPL-3.0). See
[LICENSE](LICENSE) for details.
