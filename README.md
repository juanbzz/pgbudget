<div align="center">
  <img src="pgbudget.png" alt="pgbudget" width="200"/>
</div>

# pgbudget

A PostgreSQL-based zero-sum budgeting database engine that implements double-entry accounting principles for personal finance applications.

## What it is

pgbudget provides a complete database foundation for zero-sum budgeting applications (similar to YNAB). It handles the complex accounting logic so you can focus on building user interfaces and application features.

The system implements proper double-entry accounting where every transaction affects two accounts, ensuring mathematical accuracy and providing a complete audit trail. Budget categories function as equity accounts that track your financial intentions, while asset and liability accounts track your actual money.

## Features

- **Complete budgeting workflow**: Create ledgers, accounts, categories, and transactions
- **Category groups**: Organize categories into logical groups (Household, Transportation, etc.)
- **Zero-sum budgeting**: Every dollar gets assigned a job through proper allocation
- **Double-entry accounting**: All transactions maintain accounting equation balance
- **Multi-tenant support**: Row-level security for multiple users
- **Real-time balance calculations**: On-demand account balance computation
- **Transaction history**: Complete audit trail with running balances
- **Budget status reporting**: Track budgeted vs spent amounts per category
- **Group-filtered reporting**: View budget totals filtered by category groups
- **Error correction**: Functions to correct or delete transactions with audit trail

## Requirements

- PostgreSQL 12 or higher
- [Goose](https://github.com/pressly/goose) for database migrations

## Setup

1. Create a PostgreSQL database
2. Run migrations:

```bash
goose -dir migrations postgres "your-connection-string" up
```

3. Set user context for each session:

```sql
SELECT set_config('app.current_user_id', 'your_user_id', false);
```

## API Reference

All monetary amounts are stored as integers (cents). $10.00 = 1000 cents.

### Core Functions

**Create a ledger (budget):**
```sql
INSERT INTO api.ledgers (name) VALUES ('My Budget') RETURNING uuid;
```

Example output:
```
   uuid   
----------
 d3pOOf6t
```

**Create an account:**
```sql
INSERT INTO api.accounts (ledger_uuid, name, type)
VALUES ('d3pOOf6t', 'Checking', 'asset') RETURNING uuid;
```

Example output:
```
   uuid   
----------
 aK9sLp0Q
```

**Create a budget category:**
```sql
SELECT uuid FROM api.add_category('d3pOOf6t', 'Groceries');
```

Example output:
```
   uuid   
----------
 mN8xPqR3
```

**Add income:**
```sql
SELECT api.add_transaction(
    'd3pOOf6t', NOW(), 'Paycheck', 'inflow', 100000,
    'aK9sLp0Q', (SELECT uuid FROM api.accounts 
                 WHERE ledger_uuid = 'd3pOOf6t' AND name = 'Income')
);
```

Example output:
```
 add_transaction 
-----------------
 xY7zPqR2
```

**Assign money to category:**
```sql
SELECT uuid FROM api.assign_to_category(
    'd3pOOf6t', NOW(), 'Budget: Groceries', 20000, 'mN8xPqR3'
);
```

Example output:
```
   uuid   
----------
 bK2tQw9L
```

**Record spending:**
```sql
SELECT api.add_transaction(
    'd3pOOf6t', NOW(), 'Grocery shopping', 'outflow', 5000,
    'aK9sLp0Q', 'mN8xPqR3'
);
```

Example output:
```
 add_transaction 
-----------------
 cL3uRx8M
```

### Category Groups

Organize your categories into logical groups for better budget management and reporting.

**Create category groups:**
```sql
-- Create groups with optional description and sort order
SELECT api.add_group('d3pOOf6t', 'Household', 'Home and family expenses', 1);
SELECT api.add_group('d3pOOf6t', 'Transportation', 'Car, gas, and travel', 2);
SELECT api.add_group('d3pOOf6t', 'Savings Goals', 'Emergency fund and goals', 3);
```

Example output:
```
 add_group 
-----------
 hG8kLm2N
```

**View all groups:**
```sql
SELECT * FROM api.get_groups('d3pOOf6t') ORDER BY sort_order;
```

Example output:
```
   uuid   |     name       |       description        | sort_order |        created_at
----------+----------------+--------------------------+------------+---------------------------
 hG8kLm2N | Household      | Home and family expenses |          1 | 2025-08-24 10:00:00+00
 tR5pQw9X | Transportation | Car, gas, and travel     |          2 | 2025-08-24 10:01:00+00
 sV7nUi4K | Savings Goals  | Emergency fund and goals |          3 | 2025-08-24 10:02:00+00
```

**Assign categories to groups:**
```sql
-- Assign categories to groups
SELECT api.assign_category_to_group('mN8xPqR3', 'hG8kLm2N'); -- Groceries → Household
SELECT api.assign_category_to_group('pQ4vWx7N', 'hG8kLm2N'); -- Rent → Household
SELECT api.assign_category_to_group('zK9sLp0Q', 'tR5pQw9X'); -- Gas → Transportation

-- Remove category from group (make it ungrouped)
SELECT api.assign_category_to_group('rT8yUi2P', null); -- Entertainment → ungrouped
```

**Budget totals by group:**
```sql
-- Get budget totals for a specific group
SELECT * FROM api.get_budget_totals('d3pOOf6t', null, 'hG8kLm2N');
```

Example output:
```
 income | income_remaining_from_last_month | budgeted | left_to_budget 
--------+----------------------------------+----------+----------------
      0 |                                0 |   230000 |              0
```

*Note: When filtering by group, income-related fields show 0 since income is not attributed to specific groups. The `budgeted` amount shows total budgeted for categories in the Household group ($2,300).*

**Delete a group:**
```sql
SELECT api.delete_group('hG8kLm2N');
```

*When a group is deleted, all categories in that group become ungrouped (group_id = null). Transaction history is preserved to maintain the immutable accounting principle.*

### Reporting Functions

**Budget status:**
```sql
SELECT * FROM api.get_budget_status('d3pOOf6t');
```

Example output:
```
 category_uuid | category_name | budgeted | activity | balance 
---------------+---------------+----------+----------+---------
 r95bZcwu      | Groceries     |    40000 |    -8500 |   31500
 P6lNFJrD      | Rent          |   120000 |  -120000 |       0
 rqFGEd8I      | Utilities     |    15000 |    -7500 |    7500
```

**Budget status for specific month:**
```sql
-- August 2025 budget activity
SELECT * FROM api.get_budget_status('d3pOOf6t', '202508');

-- Current month budget activity
SELECT * FROM api.get_budget_status('d3pOOf6t', TO_CHAR(CURRENT_DATE, 'YYYYMM'));
```

The period parameter format is `YYYYMM` (e.g., `202508` for August 2025). When provided, the function shows only budget assignments and spending that occurred within that month.

Example output:
```
 category_uuid | category_name | budgeted | activity | balance 
---------------+---------------+----------+----------+---------
 r95bZcwu      | Groceries     |    20000 |    -4250 |   15750
 P6lNFJrD      | Rent          |   120000 |  -120000 |       0
 rqFGEd8I      | Utilities     |     7500 |    -3750 |    3750
```

**Budget totals:**
```sql
-- All categories (existing functionality)
SELECT * FROM api.get_budget_totals('d3pOOf6t');

-- Specific group only
SELECT * FROM api.get_budget_totals('d3pOOf6t', null, 'hG8kLm2N');

-- Month view with group filtering
SELECT * FROM api.get_budget_totals('d3pOOf6t', '202508', 'tR5pQw9X');
```

Example output (all categories):
```
 income | income_remaining_from_last_month | budgeted | left_to_budget 
--------+----------------------------------+----------+----------------
 350000 |                                0 |   175000 |         175000
```

Example output (Household group):
```
 income | income_remaining_from_last_month | budgeted | left_to_budget 
--------+----------------------------------+----------+----------------
      0 |                                0 |   140000 |              0
```

**Budget totals for specific month:**
```sql
SELECT * FROM api.get_budget_totals('d3pOOf6t', '202508');
```

Example output:
```
 income | income_remaining_from_last_month | budgeted | left_to_budget 
--------+----------------------------------+----------+----------------
 175000 |                            87500 |    87500 |          87500
```

**Understanding budget totals:**
- **income**: Total income received in the period (0 when filtering by group)
- **income_remaining_from_last_month**: Income balance carried over from previous month (month view only, 0 for groups)
- **budgeted**: Total amount assigned to categories in the period (or group)
- **left_to_budget**: Current balance of Income account (0 when filtering by group)

*Note: When filtering by group, income-related fields show 0 since income is not attributed to specific groups.*

**Account balance:**
```sql
SELECT api.get_account_balance('aK9sLp0Q');
```

Example output:
```
 get_account_balance 
---------------------
               95000
```

**Transaction history:**
```sql
SELECT * FROM api.get_account_transactions('aK9sLp0Q');
```

Example output:
```
    date    |  category  |   description    |  type   | amount | running_balance 
------------+------------+------------------+---------+--------+-----------------
 2025-08-24 | Groceries  | Grocery shopping | outflow |   5000 |           95000
 2025-08-24 | Income     | Paycheck         | inflow  | 100000 |          100000
```

**All account balances:**
```sql
SELECT * FROM api.get_ledger_balances('d3pOOf6t');
```

Example output:
```
 account_uuid | account_name  | account_type | current_balance 
--------------+---------------+--------------+-----------------
 aK9sLp0Q     | Checking      | asset        |           95000
 pQ4vWx7N     | Income        | equity       |           72500
 mN8xPqR3     | Groceries     | equity       |           15000
 zKHL0bud     | Internet      | equity       |               0
 rT8yUi2P     | Off-budget    | equity       |               0
 sV9zOj3Q     | Unassigned    | equity       |               0
```

### Transaction Management

**Correct a transaction:**
```sql
SELECT api.correct_transaction(
    'cL3uRx8M', 'outflow', 'aK9sLp0Q', 'mN8xPqR3',
    6000, 'Updated grocery shopping', NOW(), 'Amount correction'
);
```

Example output:
```
 correct_transaction 
---------------------
 dM4vSy9N
```

**Delete a transaction:**
```sql
SELECT api.delete_transaction('cL3uRx8M', 'Duplicate transaction');
```

Example output:
```
 delete_transaction 
--------------------
 eN5wTz0O
```

## Default Accounts

Each ledger automatically creates three special accounts:

- **Income**: Holds unallocated funds until assigned to categories
- **Off-budget**: For tracking transactions outside your budget
- **Unassigned**: Default category for uncategorized transactions

## Complete Budget Workflow with Groups

Here's a realistic example of setting up a budget with category groups:

```sql
-- Set user context
SELECT set_config('app.current_user_id', 'user123', false);

-- 1. Create a ledger
INSERT INTO api.ledgers (name) VALUES ('Monthly Budget') RETURNING uuid;
-- Returns: 'd3pOOf6t'

-- 2. Create a checking account
INSERT INTO api.accounts (ledger_uuid, name, type) 
VALUES ('d3pOOf6t', 'Chase Checking', 'asset') RETURNING uuid;
-- Returns: 'aK9sLp0Q'

-- 3. Create category groups
SELECT api.add_group('d3pOOf6t', 'Household', 'Home and family expenses', 1);
-- Returns: 'hG8kLm2N'
SELECT api.add_group('d3pOOf6t', 'Transportation', 'Car and travel', 2);
-- Returns: 'tR5pQw9X'

-- 4. Create categories
SELECT uuid FROM api.add_category('d3pOOf6t', 'Groceries');
-- Returns: 'mN8xPqR3'
SELECT uuid FROM api.add_category('d3pOOf6t', 'Rent');
-- Returns: 'pQ4vWx7N'
SELECT uuid FROM api.add_category('d3pOOf6t', 'Gas');
-- Returns: 'zK9sLp0Q'
SELECT uuid FROM api.add_category('d3pOOf6t', 'Entertainment');
-- Returns: 'rT8yUi2P'

-- 5. Assign categories to groups
SELECT api.assign_category_to_group('mN8xPqR3', 'hG8kLm2N'); -- Groceries → Household
SELECT api.assign_category_to_group('pQ4vWx7N', 'hG8kLm2N'); -- Rent → Household
SELECT api.assign_category_to_group('zK9sLp0Q', 'tR5pQw9X'); -- Gas → Transportation
-- Entertainment remains ungrouped

-- 6. Add monthly income
SELECT api.add_transaction(
    'd3pOOf6t', NOW(), 'Salary Deposit', 'inflow', 500000,
    'aK9sLp0Q', (SELECT uuid FROM api.accounts 
                 WHERE ledger_uuid = 'd3pOOf6t' AND name = 'Income')
);
-- Returns: 'xY7zPqR2'

-- 7. Budget money to categories
SELECT uuid FROM api.assign_to_category('d3pOOf6t', NOW(), 'Budget: Groceries', 60000, 'mN8xPqR3');
-- Returns: 'bK2tQw9L'
SELECT uuid FROM api.assign_to_category('d3pOOf6t', NOW(), 'Budget: Rent', 150000, 'pQ4vWx7N');
-- Returns: 'cL3uRx8M'
SELECT uuid FROM api.assign_to_category('d3pOOf6t', NOW(), 'Budget: Gas', 25000, 'zK9sLp0Q');
-- Returns: 'dM4vSy9N'
SELECT uuid FROM api.assign_to_category('d3pOOf6t', NOW(), 'Budget: Entertainment', 15000, 'rT8yUi2P');
-- Returns: 'eN5wTz0O'

-- 8. Record some spending
SELECT api.add_transaction(
    'd3pOOf6t', NOW(), 'Whole Foods', 'outflow', 12000,
    'aK9sLp0Q', 'mN8xPqR3'
);
-- Returns: 'fO6xUa1P'

SELECT api.add_transaction(
    'd3pOOf6t', NOW(), 'Shell Gas Station', 'outflow', 8000,
    'aK9sLp0Q', 'zK9sLp0Q'
);
-- Returns: 'gP7yVb2Q'

-- 9. Check budget totals by group
SELECT * FROM api.get_budget_totals('d3pOOf6t', null, 'hG8kLm2N'); -- Household group
-- Returns:
--  income | income_remaining_from_last_month | budgeted | left_to_budget 
-- --------+----------------------------------+----------+----------------
--       0 |                                0 |   210000 |              0

SELECT * FROM api.get_budget_totals('d3pOOf6t', null, 'tR5pQw9X'); -- Transportation group  
-- Returns:
--  income | income_remaining_from_last_month | budgeted | left_to_budget 
-- --------+----------------------------------+----------+----------------
--       0 |                                0 |    25000 |              0

SELECT * FROM api.get_budget_totals('d3pOOf6t'); -- All categories
-- Returns:
--  income | income_remaining_from_last_month | budgeted | left_to_budget 
-- --------+----------------------------------+----------+----------------
--  500000 |                                0 |   250000 |         250000

-- 10. Check budget status (shows spending activity)
SELECT * FROM api.get_budget_status('d3pOOf6t');
-- Returns:
--  category_uuid | category_name | budgeted | activity | balance 
-- ---------------+---------------+----------+----------+---------
--  mN8xPqR3      | Groceries     |    60000 |   -12000 |   48000
--  pQ4vWx7N      | Rent          |   150000 |        0 |  150000
--  zK9sLp0Q      | Gas           |    25000 |    -8000 |   17000
--  rT8yUi2P      | Entertainment |    15000 |        0 |   15000
```

## Example Workflow

```sql
-- Set user context
SELECT set_config('app.current_user_id', 'user123', false);
-- Returns: set_config
--          ------------
--          

-- Create budget
INSERT INTO api.ledgers (name) VALUES ('Monthly Budget') RETURNING uuid;
-- Returns:
--    uuid   
-- ----------
--  d3pOOf6t

-- Create checking account
INSERT INTO api.accounts (ledger_uuid, name, type)
VALUES ('d3pOOf6t', 'Checking', 'asset') RETURNING uuid;
-- Returns:
--    uuid   
-- ----------
--  aK9sLp0Q

-- Create grocery category
SELECT uuid FROM api.add_category('d3pOOf6t', 'Groceries');
-- Returns:
--    uuid   
-- ----------
--  mN8xPqR3

-- Add $1000 income
SELECT api.add_transaction(
    'd3pOOf6t', NOW(), 'Paycheck', 'inflow', 100000,
    'aK9sLp0Q', (SELECT uuid FROM api.accounts 
                 WHERE ledger_uuid = 'd3pOOf6t' AND name = 'Income')
);
-- Returns:
--  add_transaction 
-- -----------------
--  xY7zPqR2

-- Assign $200 to groceries
SELECT uuid FROM api.assign_to_category(
    'd3pOOf6t', NOW(), 'Budget: Groceries', 20000, 'mN8xPqR3'
);
-- Returns:
--    uuid   
-- ----------
--  bK2tQw9L

-- Spend $50 on groceries
SELECT api.add_transaction(
    'd3pOOf6t', NOW(), 'Grocery shopping', 'outflow', 5000,
    'aK9sLp0Q', 'mN8xPqR3'
);
-- Returns:
--  add_transaction 
-- -----------------
--  cL3uRx8M

-- Check budget status
SELECT * FROM api.get_budget_status('d3pOOf6t');
-- Returns:
--  category_uuid | category_name | budgeted | activity | balance 
-- ---------------+---------------+----------+----------+---------
--  mN8xPqR3      | Groceries     |    20000 |    -5000 |   15000
--  pQ4vWx7N      | Income        |        0 |        0 |   80000
```

## Architecture

The database uses a three-schema design:

- **`data`**: Raw tables and constraints
- **`utils`**: Internal business logic functions
- **`api`**: Public interface functions with UUID parameters

This separation ensures clean interfaces while maintaining internal flexibility.

## License

Licensed under GNU Affero General Public License v3.0 (AGPL-3.0). See [LICENSE](LICENSE) for details.