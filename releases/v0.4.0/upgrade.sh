#!/bin/bash
# pgbudget v0.3.0 -> v0.4.0 Upgrade Script

set -e

if [ -z "$DATABASE_URL" ]; then
    echo "Error: Please set DATABASE_URL environment variable"
    exit 1
fi

echo "Upgrading pgbudget from v0.3.0 to v0.4.0..."
psql "$DATABASE_URL" -f upgrade_from_v0.3.0.sql
echo "Upgrade complete!"
