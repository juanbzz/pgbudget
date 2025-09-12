# CRUSH Configuration

## Build/Test Commands
- **Run all tests**: `go test -v ./...`
- **Run single test**: `go test -v -run TestName`
- **Run tests with coverage**: `go test -v -cover ./...`
- **Build**: `go build`
- **Format code**: `go fmt ./...`
- **Lint**: `go vet ./...`
- **Tidy dependencies**: `go mod tidy`

## Database Commands (via Task)
- **Run migrations**: `task migrate:up`
- **Create migration**: `task migrate:new -- migration_name`
- **Migration status**: `task migrate:status`
- **Rollback migration**: `task migrate:down`

## Code Style Guidelines

### PostgreSQL Conventions
- Write SQL queries in lowercase (strings can be any case)
- Always add comments above SQL queries explaining each step
- Use `data` schema for data shape definitions
- Use `api` schema for functions that modify data
- Use `utils` schema for internal utility functions
- Primary keys: `bigint generated always as identity`
- Prefer table constraints over column constraints
- Constraint naming: `<table>_<column>_<constraint>_<type>`

### Schema Separation Pattern
**CRITICAL**: Always follow this separation of concerns between schemas:

**`api` schema (Public Interface):**
- Functions take UUID parameters (user-friendly)
- Thin wrappers that call `utils` functions
- Convert UUIDs to text and pass to utils
- Convert returned IDs back to UUIDs
- Minimal business logic - just parameter conversion
- Example: `api.add_transaction(uuid, text, uuid)` → calls `utils.add_transaction(text, text, text)`

**`utils` schema (Internal Business Logic):**
- Functions take text parameters (for legacy UUID compatibility)
- Handle all UUID→ID conversion internally
- Contain all business logic (validation, double-entry rules, etc.)
- Work with internal IDs (bigint) for database operations
- Handle special cases like "Unassigned" category lookup
- Return IDs (int/bigint) to api functions

**`data` schema (Raw Data):**
- Tables and basic constraints only
- No business logic
- Direct access discouraged for mutations

**Example Pattern:**
```sql
-- utils function (business logic)
CREATE FUNCTION utils.add_transaction(
    p_ledger_uuid text,
    p_account_uuid text,
    p_category_uuid text
) RETURNS int AS $$
-- All the complex logic here
$$;

-- api function (thin wrapper)
CREATE FUNCTION api.add_transaction(
    p_ledger_uuid uuid,
    p_account_uuid uuid,
    p_category_uuid uuid
) RETURNS uuid AS $$
BEGIN
    -- Just convert and delegate
    SELECT utils.add_transaction(
        p_ledger_uuid::text,
        p_account_uuid::text,
        p_category_uuid::text
    ) INTO v_id;
    -- Convert ID back to UUID and return
END;
$$;
```

### Go Conventions
- Follow standard Go formatting (gofmt)
- Use meaningful variable names
- Import aliases: `is_ "github.com/matryer/is"` for test assertions
- Error handling: Always check and handle errors appropriately
- Test structure: Use nested subtests with `t.Run()` for organization
- Use `context.Background()` for database operations in tests
- Store UUIDs as strings, internal IDs as int

### Testing
- Use `github.com/matryer/is` for test assertions
- Create dedicated test ledgers/accounts for each test suite
- Use `setupTestLedger()` helper for complex test scenarios
- Test both success and error cases
- Verify database state after operations

## API Functions Reference

### Category Groups

**Create Group:**
```sql
SELECT api.add_group('ledger-uuid', 'Group Name', 'Optional description', 1);
```

**Get All Groups:**
```sql
SELECT * FROM api.get_groups('ledger-uuid') ORDER BY sort_order;
```

**Assign Category to Group:**
```sql
SELECT api.assign_category_to_group('category-uuid', 'group-uuid');
-- Or remove from group:
SELECT api.assign_category_to_group('category-uuid', null);
```

**Delete Group (orphans categories):**
```sql
SELECT api.delete_group('group-uuid');
```

### Core Budget Functions

**Budget Status (Category Details):**
```sql
-- All-time view
SELECT * FROM api.get_budget_status('ledger-uuid');

-- Month view (YYYYMM format)
SELECT * FROM api.get_budget_status('ledger-uuid', '202508');
```

**Budget Totals (Summary Data):**
```sql
-- All-time totals
SELECT * FROM api.get_budget_totals('ledger-uuid');

-- Month totals (YYYYMM format)  
SELECT * FROM api.get_budget_totals('ledger-uuid', '202508');

-- Group totals (all-time)
SELECT * FROM api.get_budget_totals('ledger-uuid', null, 'group-uuid');

-- Group totals (month view)
SELECT * FROM api.get_budget_totals('ledger-uuid', '202508', 'group-uuid');
```

**Budget Totals Fields:**
- `income`: Total income received in period
- `income_remaining_from_last_month`: Carryover from previous month (month view only)
- `budgeted`: Total assigned to categories in period
- `left_to_budget`: Current Income account balance

### Transaction Functions

**Add Income:**
```sql
INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
VALUES ('ledger-uuid', NOW(), 'Paycheck', 'inflow', 100000, 'account-uuid', 'income-uuid');
```

**Assign to Category:**
```sql
SELECT uuid FROM api.assign_to_category('ledger-uuid', NOW(), 'Budget: Groceries', 20000, 'category-uuid');
```

**Record Spending:**
```sql
INSERT INTO api.transactions (ledger_uuid, date, description, type, amount, account_uuid, category_uuid)
VALUES ('ledger-uuid', NOW(), 'Grocery shopping', 'outflow', 5000, 'account-uuid', 'category-uuid');
```

### Account Functions

**Create Category:**
```sql
SELECT uuid FROM api.add_category('ledger-uuid', 'Category Name');
```

**Get Account Balance:**
```sql
SELECT api.get_account_balance('account-uuid');
```

**Get Account Transactions:**
```sql
SELECT * FROM api.get_account_transactions('account-uuid');
```

## Month View Pattern

**YYYYMM Format**: Use 6-digit format for periods (e.g., '202508' for August 2025)

**Current Month Helper:**
```sql
TO_CHAR(CURRENT_DATE, 'YYYYMM')
```

**Date Range Logic:**
- Start: First day of month (`YYYY-MM-01`)
- End: Last day of month or today (whichever is earlier)

## Common Patterns

### Complete Budget Setup
```sql
-- Set user context
SELECT set_config('app.current_user_id', 'user_id', false);

-- Create ledger
INSERT INTO api.ledgers (name) VALUES ('My Budget') RETURNING uuid;

-- Create account  
INSERT INTO api.accounts (ledger_uuid, name, type) VALUES ('ledger-uuid', 'Checking', 'asset');

-- Create categories
SELECT uuid FROM api.add_category('ledger-uuid', 'Groceries');
SELECT uuid FROM api.add_category('ledger-uuid', 'Rent');

-- Add income → Budget → Spend workflow
```

### Realistic Test Data
Use realistic category names and amounts:
- **Groceries**: $400 budgeted, $85 spent
- **Rent**: $1,200 budgeted, $1,200 spent  
- **Utilities**: $150 budgeted, $75 spent
- **Income**: $3,500 monthly salary

## Migration Best Practices

### Function Updates
- Drop existing function before recreating with new signature
- Always include proper rollback in `-- +goose Down`
- Test migration up/down cycle before committing

### Schema Changes
- Follow existing naming conventions
- Add comments explaining business logic
- Maintain backward compatibility when possible

## Debugging Tips

### Check Function Signatures
```sql
\df api.*           -- List all api functions
\df+ function_name  -- Show function details
```

### Test User Context
```sql
SELECT set_config('app.current_user_id', 'test_user', false);
SELECT current_setting('app.current_user_id', true);
```

### Verify Data
```sql
-- Check account balances
SELECT * FROM api.get_ledger_balances('ledger-uuid');

-- Check transaction history  
SELECT * FROM api.get_account_transactions('account-uuid');

-- Debug budget calculations
SELECT * FROM utils.get_budget_status('ledger-uuid', utils.get_user(), null, null);
```