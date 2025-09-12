#!/bin/bash
set -e

# pgbudget Release Script
# Generates complete schema and upgrade files for a new release

VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 v0.4.0"
    exit 1
fi

# Validate version format
if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: Version must be in format vX.Y.Z (e.g., v0.4.0)"
    exit 1
fi

echo "Creating release artifacts for $VERSION..."

# Create release directory
RELEASE_DIR="releases/$VERSION"
mkdir -p "$RELEASE_DIR"

# Determine previous version for upgrade script
PREV_VERSION=""
if [ -f "VERSION" ]; then
    CURRENT=$(cat VERSION)
    if [[ "$CURRENT" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        PREV_VERSION="$CURRENT"
    fi
fi

echo "Previous version: ${PREV_VERSION:-unknown}"

# Generate complete schema.sql from migrations
echo "Generating complete schema..."
{
    echo "-- pgbudget $VERSION - Complete Schema"
    echo "-- Generated on $(date)"
    echo "-- For fresh installations"
    echo ""
    echo "-- Create schemas"
    echo "CREATE SCHEMA IF NOT EXISTS data;"
    echo "CREATE SCHEMA IF NOT EXISTS utils;"
    echo "CREATE SCHEMA IF NOT EXISTS api;"
    echo ""
    
    # Process migrations in chronological order
    for migration in migrations/*.sql; do
        if [ -f "$migration" ]; then
            echo "-- From: $(basename "$migration")"
            
            # Extract SQL between +goose Up and +goose Down
            awk '
                BEGIN { in_up = 0 }
                /-- \+goose Up/ { in_up = 1; next }
                /-- \+goose Down/ { in_up = 0; next }
                /-- \+goose StatementBegin/ && in_up { next }
                /-- \+goose StatementEnd/ && in_up { next }
                in_up { print }
            ' "$migration"
            echo ""
        fi
    done
    
    echo "-- Set version"
    echo "INSERT INTO utils.metadata (key, value) VALUES ('version', '$VERSION') ON CONFLICT (key) DO UPDATE SET value = '$VERSION';"
} > "$RELEASE_DIR/schema.sql"

# Generate upgrade script if we know the previous version
if [ -n "$PREV_VERSION" ]; then
    echo "Generating upgrade script from $PREV_VERSION..."
    
    {
        echo "-- pgbudget $PREV_VERSION -> $VERSION Upgrade"
        echo "-- Generated on $(date)"
        echo "-- This file upgrades an existing $PREV_VERSION installation"
        echo ""
        
        echo "-- Version check"
        echo "DO \$\$"
        echo "BEGIN"
        echo "    -- Check that we're running the expected version"
        echo "    IF NOT EXISTS ("
        echo "        SELECT 1 FROM utils.metadata" 
        echo "        WHERE key = 'version' AND value = '$PREV_VERSION'"
        echo "    ) THEN"
        echo "        RAISE EXCEPTION 'This upgrade requires pgbudget $PREV_VERSION. Current version check failed.';"
        echo "    END IF;"
        echo "END \$\$;"
        echo ""
        
        # Find migrations that are new since the previous version
        # This is a simplified approach - in reality, we'd need to track which migrations were in which version
        case "$VERSION" in
            "v0.4.0")
                echo "-- Category Groups Feature Migrations"
                echo ""
                
                # Add the 3 group migrations
                for migration in migrations/20250824214953_add_groups_table.sql \
                               migrations/20250824220136_add_group_id_to_categories.sql \
                               migrations/20250824220411_add_group_api_functions.sql; do
                    if [ -f "$migration" ]; then
                        echo "-- From: $(basename "$migration")"
                        
                        # Extract SQL between +goose Up and +goose Down
                        awk '
                            BEGIN { in_up = 0 }
                            /-- \+goose Up/ { in_up = 1; next }
                            /-- \+goose Down/ { in_up = 0; next }
                            /-- \+goose StatementBegin/ && in_up { next }
                            /-- \+goose StatementEnd/ && in_up { next }
                            in_up { print }
                        ' "$migration"
                        echo ""
                    fi
                done
                ;;
        esac
        
        echo "-- Update version"
        echo "INSERT INTO utils.metadata (key, value) VALUES ('version', '$VERSION') ON CONFLICT (key) DO UPDATE SET value = '$VERSION';"
        echo ""
        echo "-- Upgrade complete"
        echo "SELECT 'Upgrade to $VERSION completed successfully' AS result;"
        
    } > "$RELEASE_DIR/upgrade_from_$PREV_VERSION.sql"
fi

# Copy CHANGELOG section for this version
echo "Extracting changelog..."
{
    echo "# pgbudget $VERSION Release Notes"
    echo ""
    
    # Extract the changelog section for this version
    awk "
        /^## \[$VERSION\]/ { in_section = 1; next }
        /^## \[/ && in_section { exit }
        in_section { print }
    " CHANGELOG.md
} > "$RELEASE_DIR/CHANGELOG.md"

# Create installation script
echo "Creating installation script..."
{
    echo "#!/bin/bash"
    echo "# pgbudget $VERSION Installation Script"
    echo ""
    echo 'set -e'
    echo ""
    echo 'if [ -z "$DATABASE_URL" ]; then'
    echo '    echo "Error: Please set DATABASE_URL environment variable"'
    echo '    echo "Example: export DATABASE_URL=\"postgres://user:pass@localhost:5432/dbname\""'
    echo '    exit 1'
    echo 'fi'
    echo ""
    echo 'echo "Installing pgbudget '$VERSION'..."'
    echo 'psql "$DATABASE_URL" -f schema.sql'
    echo 'echo "Installation complete!"'
    echo ""
    echo 'echo "Usage:"'
    echo 'echo "  1. Set user context: SELECT set_config('\''app.current_user_id'\'', '\''your_user_id'\'', false);"'
    echo 'echo "  2. Create ledger: INSERT INTO api.ledgers (name) VALUES ('\''My Budget'\'') RETURNING uuid;"'
    echo 'echo "  3. See README.md for full API documentation"'
} > "$RELEASE_DIR/install.sh"

chmod +x "$RELEASE_DIR/install.sh"

# Create upgrade script
if [ -n "$PREV_VERSION" ]; then
    {
        echo "#!/bin/bash"
        echo "# pgbudget $PREV_VERSION -> $VERSION Upgrade Script"
        echo ""
        echo 'set -e'
        echo ""
        echo 'if [ -z "$DATABASE_URL" ]; then'
        echo '    echo "Error: Please set DATABASE_URL environment variable"'
        echo '    exit 1'
        echo 'fi'
        echo ""
        echo 'echo "Upgrading pgbudget from '$PREV_VERSION' to '$VERSION'..."'
        echo 'psql "$DATABASE_URL" -f upgrade_from_'$PREV_VERSION'.sql'
        echo 'echo "Upgrade complete!"'
    } > "$RELEASE_DIR/upgrade.sh"
    
    chmod +x "$RELEASE_DIR/upgrade.sh"
fi

echo ""
echo "✅ Release artifacts generated in $RELEASE_DIR/"
echo ""
echo "Files created:"
echo "  📄 schema.sql - Complete database schema for fresh installs"
if [ -n "$PREV_VERSION" ]; then
    echo "  📄 upgrade_from_$PREV_VERSION.sql - Upgrade script from $PREV_VERSION"
    echo "  🔧 upgrade.sh - Upgrade script wrapper"
fi
echo "  📄 CHANGELOG.md - Release notes for $VERSION"
echo "  🔧 install.sh - Installation script wrapper"
echo ""
echo "Next steps:"
echo "  1. Review generated files"
echo "  2. Test fresh installation: cd $RELEASE_DIR && ./install.sh"
if [ -n "$PREV_VERSION" ]; then
    echo "  3. Test upgrade: cd $RELEASE_DIR && ./upgrade.sh"
fi
echo "  4. Create git tag: git tag $VERSION"
echo "  5. Commit and push: git add . && git commit -m 'Release $VERSION' && git push --tags"