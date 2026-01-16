#!/bin/bash
set -e

echo "⚠️  This will DELETE all data and reinitialize the database!"
read -p "Are you sure? (yes/no): " -r
echo

if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    echo "Cancelled"
    exit 1
fi

echo "🗑️  Dropping and recreating database..."

docker exec nowplaying-db psql -U nowplaying -d postgres -c "DROP DATABASE IF EXISTS nowplaying;"
docker exec nowplaying-db psql -U nowplaying -d postgres -c "CREATE DATABASE nowplaying;"

echo "📋 Applying schema..."
docker exec -i nowplaying-db psql -U nowplaying -d nowplaying < ../database/schema.sql

echo "✅ Database reset complete"
