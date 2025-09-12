#!/bin/bash
# pgbudget Installation Script
# Installs the latest release version

set -e

VERSION="${1:-v0.4.0}"

echo "Installing pgbudget $VERSION..."

if [ ! -d "releases/$VERSION" ]; then
    echo "Error: Release $VERSION not found"
    echo "Available releases:"
    ls -1 releases/ 2>/dev/null || echo "  (none)"
    exit 1
fi

if [ -z "$DATABASE_URL" ]; then
    echo "Error: Please set DATABASE_URL environment variable"
    echo "Example: export DATABASE_URL=\"postgres://user:pass@localhost:5432/dbname\""
    exit 1
fi

cd "releases/$VERSION"
./install.sh

echo ""
echo "✅ pgbudget $VERSION installed successfully!"
echo ""
echo "Quick start:"
echo "  1. Set user context:"
echo "     SELECT set_config('app.current_user_id', 'your_user_id', false);"
echo ""
echo "  2. Create your first budget:"
echo "     INSERT INTO api.ledgers (name) VALUES ('My Budget') RETURNING uuid;"
echo ""
echo "  3. See README.md for full documentation"