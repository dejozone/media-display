#!/bin/bash
set -e

echo "🚀 Starting Now Playing services..."

# Load environment variables from docker/.env file
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Start PostgreSQL
echo "📦 Starting PostgreSQL..."
docker-compose up -d postgres

# Wait for PostgreSQL to be ready
echo "⏳ Waiting for PostgreSQL to be ready..."
until docker exec nowplaying-db pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} > /dev/null 2>&1; do
    sleep 1
done

echo "✅ PostgreSQL is ready"

# Check if schema needs to be initialized manually
if [ "$INIT_SCHEMA" != "true" ]; then
    echo ""
    echo "⚠️  Schema not initialized automatically (INIT_SCHEMA=false)"
    echo "To initialize the schema manually, run:"
    echo "  ./init-schema.sh"
    echo ""
fi

echo "✅ Services started successfully"
echo ""
echo "📊 Service URLs:"
echo "  PostgreSQL: localhost:5432"
echo "  Database:   nowplaying"
echo "  User:       ${POSTGRES_USER}"
echo ""
echo "To view logs: docker-compose logs -f postgres"
echo "To stop:      ./stop.sh"
