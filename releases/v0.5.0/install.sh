#!/bin/bash
# pgbudget v0.5.0 Installation Script

set -e

if [ -z "$DATABASE_URL" ]; then
    echo "Error: Please set DATABASE_URL environment variable"
    echo "Example: export DATABASE_URL=\"postgres://user:pass@localhost:5432/dbname\""
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing pgbudget v0.5.0..."
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$SCRIPT_DIR/schema.sql"
echo "Installation complete!"

echo ""
echo "Usage (ledger engine):"
echo "  1. Set user context:    SELECT set_config('app.current_user_id', 'your_user_id', false);"
echo "  2. Create a ledger:     SELECT ledger.create_ledger('My Ledger');"
echo "  3. Create accounts:     SELECT ledger.create_account(<ledger_uuid>, 'Checking');"
echo "  4. Post transactions:   SELECT ledger.post_transaction(<ledger_uuid>, <debit_uuid>, <credit_uuid>, 1000);"
echo ""
echo "Note: v0.5.0 ships the ledger engine only. The budget application layer will land in v1.0.0."
