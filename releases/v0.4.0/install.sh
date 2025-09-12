#!/bin/bash
# pgbudget v0.4.0 Installation Script

set -e

if [ -z "$DATABASE_URL" ]; then
    echo "Error: Please set DATABASE_URL environment variable"
    echo "Example: export DATABASE_URL=\"postgres://user:pass@localhost:5432/dbname\""
    exit 1
fi

echo "Installing pgbudget v0.4.0..."
psql "$DATABASE_URL" -f schema.sql
echo "Installation complete!"

echo "Usage:"
echo "  1. Set user context: SELECT set_config('app.current_user_id', 'your_user_id', false);"
echo "  2. Create ledger: INSERT INTO api.ledgers (name) VALUES ('My Budget') RETURNING uuid;"
echo "  3. See README.md for full API documentation"
