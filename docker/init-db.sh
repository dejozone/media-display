#!/bin/bash
set -e

echo "🗄️  Initializing PostgreSQL database..."

# Check if schema should be initialized
if [ "$INIT_SCHEMA" = "true" ]; then
    echo "📋 INIT_SCHEMA=true, schema.sql will be applied automatically"
    echo "✅ Schema initialization enabled"
else
    echo "⏭️  INIT_SCHEMA=false, skipping schema initialization"
    echo "💡 To initialize schema manually, run:"
    echo "   docker exec -i nowplaying-db psql -U $POSTGRES_USER -d nowplaying < database/schema.sql"
fi

echo "✅ Database initialization complete"
