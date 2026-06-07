# Changelog

All notable changes to pgbudget will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Rearchitected into a generic double-entry engine.** The project is
  now two layers: a generic `ledger` engine (TigerBeetle-inspired) and a
  budgeting `budget` layer built on top. Budgeting vocabulary moves out
  of the engine and into the (planned) budget layer.
- **Removed the `api` schema and PostgREST-oriented design.** The public
  surface is now the `ledger.*` functions.
- **Removed account types.** Accounts have no `type`/`internal_type`
  columns. Accounts are containers with `debits_total`/`credits_total`
  counters; the application layer interprets them.
- **Raw counters instead of signed balances.** `ledger.get_balance()`
  returns `(debits_total, credits_total)`; callers compute signed
  balances.
- **No auto-created accounts.** `ledger.create_ledger()` creates only the
  ledger row; the caller creates the accounts it needs (including any
  clearing accounts for linked transfers).

### Added
- **Generic ledger engine (`ledger` schema).** Accounts, single and
  batch transaction posting, linked multi-leg transfers via a clearing
  account, two-phase transfers (`reserve`/`commit`/`release`/
  `expire_pending`), immutable corrections (`void`/`correct`),
  idempotency keys, account closing, account visibility, and balance
  history with atomic current counters.
- **Per-account balance constraints**
  (`debits_must_not_exceed_credits`, `credits_must_not_exceed_debits`),
  enforced on the checked write path; pending holds count against them.
- **App-defined `code` field** (smallint) on accounts and transactions
  for categorization. The engine stores and indexes it but assigns no
  meaning.

### Removed
- The budgeting `api.*` functions (category groups, budget status/totals,
  income/expense/assign helpers) pending reimplementation in the
  `budget` layer.

## [0.4.0] - 2025-08-24

### Added
- **Category Groups**: Organize categories into logical groups for better budget management
  - `api.add_group()` - Create category groups with name, description, and sort order
  - `api.get_groups()` - List all groups for a ledger ordered by sort order
  - `api.assign_category_to_group()` - Assign categories to groups or make them ungrouped
  - `api.delete_group()` - Delete group (categories become ungrouped, history preserved)
- **Group-Filtered Reporting**: Enhanced budget analysis with group-based filtering
  - `api.get_budget_totals()` now supports optional group filtering parameter
  - Group-filtered budget status reporting for targeted analysis
- **Database Schema Enhancements**:
  - `data.groups` table with RLS policies and proper constraints
  - `group_id` column added to `data.accounts` (categories) table
  - Indexes for performance on group relationships and sort order

### Enhanced
- **Budget Organization**: Categories can now be organized into logical groups (Household, Transportation, etc.)
- **Flexible Reporting**: Budget totals and status can be filtered by specific groups
- **Data Integrity**: Group deletion preserves transaction history while orphaning categories
- **User Experience**: Sort order support enables drag-and-drop UI implementations

### Technical
- **Migration Files**: 3 new migrations for complete category groups implementation
  - `20250824214953_add_groups_table.sql` - Groups table with RLS and constraints
  - `20250824220136_add_group_id_to_categories.sql` - Category-group relationships
  - `20250824220411_add_group_api_functions.sql` - Complete API function suite
- **Backward Compatibility**: All existing functionality preserved, groups are optional
- **Test Coverage**: Comprehensive test suite including group management, deletion, and reassignment scenarios

## [0.3.0] - 2025-08-23

### Added
- **Balance Snapshots System**: Fast O(1) balance lookups via `api.get_account_balance()`
- **Running Balances**: `api.get_account_transactions()` now includes `running_balance` column
- **Enhanced Error Handling**: Comprehensive validation with user-friendly error messages
- **Balance API Functions**: Complete balance management utilities
  - `api.get_ledger_balances()` - Get all account balances in a ledger
  - `api.rebuild_ledger_balance_snapshots()` - Data repair utility
- **Validation Utilities**: New validation functions for comprehensive input checking
  - `utils.validate_transaction_data()` - Transaction amount, date, and type validation
  - `utils.validate_input_data()` - Input sanitization and validation
  - `utils.handle_constraint_violation()` - User-friendly constraint error messages
- **Comprehensive Test Coverage**: 100+ test cases including 15+ new error handling scenarios
- **Balance History Tracking**: Complete balance history for every account at every transaction
- **Automatic Balance Maintenance**: Balance snapshots created and updated via triggers

### Changed
- **Performance Improvement**: Balance calculations now O(1) instead of O(n) transaction scanning
- **Enhanced Error Messages**: All validation errors now provide clear, actionable feedback
- **Code Architecture**: Eliminated duplication between API functions and view triggers
- **Transaction History**: Running balance column added to transaction history output
- **Validation Logic**: Single source of truth for validation across all functions

### Enhanced
- **Input Validation**: Names, descriptions, amounts, and dates now comprehensively validated
- **Business Rules**: Transaction amount limits ($1M max), date ranges (±10 years)
- **Constraint Handling**: Duplicate names and constraint violations show friendly messages
- **Error Context**: All error messages now include specific details and suggested fixes
- **Database Performance**: Proper indexing and efficient queries for balance operations

### Technical
- **Database Schema**: Added `data.balance_snapshots` table with automatic triggers
- **Migration Files**: 3 new migrations for enhanced error handling and balance system
- **Architecture**: Maintained backward compatibility while adding significant new features
- **Testing**: All existing functionality preserved with enhanced validation

## [0.2.0] - 2025-04-05

### Added
- Added function to calculate a balance on demand (#16)
- Added balance table and get transactions function (account view) (#17)
- Added contributing guidelines and licensing information

### Changed
- Updated changelog links and fixed version file

## [0.1.4] - 2025-04-04

### Changed
- Refactored: Moved pgcontainer to its own package for better organization
- Updated README with detailed information about bigint amount representation
- Improved documentation with clearer examples and usage instructions
- Removed redundant example transaction query from README

### Added
- Added comprehensive database amount representation details to documentation
- Added preparation for future 1.0.0 release

## [0.1.3] - 2025-04-01

### Added
- Added account view for easier transaction querying

## [0.1.2] - 2025-04-01

### Added
- Added account functions for better account management

## [0.1.1] - 2025-04-01

### Added
- Added category functions for budget management

## [0.1.0] - 2025-03-31

### Added
- Initial release with core functionality
- Refactored migrations to remove duplicate find_category function

[unreleased]: https://github.com/j0lvera/pgbudget/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/j0lvera/pgbudget/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/j0lvera/pgbudget/compare/v0.1.5...v0.2.0
[0.1.5]: https://github.com/j0lvera/pgbudget/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/j0lvera/pgbudget/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/j0lvera/pgbudget/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/j0lvera/pgbudget/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/j0lvera/pgbudget/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/j0lvera/pgbudget/releases/tag/v0.1.0
