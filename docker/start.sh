#!/bin/bash
set -e

UPDATE_SCHEMA=false

# Prefer docker compose plugin; fall back to docker-compose binary
if command -v docker &> /dev/null && docker compose version &> /dev/null; then
  DC_CMD="docker compose"
elif command -v docker-compose &> /dev/null; then
  DC_CMD="docker-compose"
else
  echo "❌ Neither 'docker compose' nor 'docker-compose' is available. Please install Docker." >&2
  exit 1
fi

while [[ "$1" != "" ]]; do
  case "$1" in
    --update-schema)
      UPDATE_SCHEMA=true
      ;;
    *)
      echo "Unknown option: $1" && exit 1
      ;;
  esac
  shift
done

echo "🚀 Starting Now Playing services..."

# Load environment variables from docker/.env file
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Service and container names
DB_SERVICE=postgres
DB_CONTAINER=nowplaying-db

# If updating schema, drop containers/volumes first for a clean start
if [ "$UPDATE_SCHEMA" = "true" ]; then
  echo "🧹 Dropping existing containers/volumes (docker compose down -v)..."
  ${DC_CMD} down -v || true
fi

# Start PostgreSQL
echo "📦 Starting PostgreSQL..."
${DC_CMD} up -d ${DB_SERVICE}

# Wait for PostgreSQL to be ready (tolerate container creation delay)
echo "⏳ Waiting for PostgreSQL to be ready..."
until docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; do
  echo "   ⏳ ${DB_CONTAINER} container not present yet, starting..."
  ${DC_CMD} up -d ${DB_SERVICE}
  sleep 1
done

until docker exec ${DB_CONTAINER} pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} > /dev/null 2>&1; do
  sleep 1
done

echo "✅ PostgreSQL is ready"

if [ "$UPDATE_SCHEMA" = "true" ]; then
  echo "📋 Applying schema (./init-schema.sh)..."
  ./init-schema.sh
fi

# Check if schema needs to be initialized manually when not updating
if [ "$UPDATE_SCHEMA" != "true" ] && [ "$INIT_SCHEMA" != "true" ]; then
    echo ""
    echo "⚠️  Schema not initialized automatically (INIT_SCHEMA=false)"
    echo "To initialize the schema manually, run:"
    echo "  ./init-schema.sh"
    echo "  or rerun start.sh with --update-schema"
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
