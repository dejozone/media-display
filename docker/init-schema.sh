#!/bin/bash
set -e

echo "📋 Initializing database schema..."

# Check if database is running
if ! docker exec nowplaying-db pg_isready -U nowplaying -d nowplaying > /dev/null 2>&1; then
    echo "❌ PostgreSQL is not running. Start it with: ./start.sh"
    exit 1
fi

# Apply schema
docker exec -i nowplaying-db psql -U nowplaying -d nowplaying < ../database/schema.sql

echo "✅ Schema initialized successfully"
