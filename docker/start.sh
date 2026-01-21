#!/bin/bash
set -e

MODE="restart"  # default: restart, reset-db, reset-schema, update-schema
SCHEMA_FILE=""

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
    --reset-db)
      MODE="reset-db"
      shift
      ;;
    --reset-schema)
      MODE="reset-schema"
      shift
      SCHEMA_FILE="$1"
      if [[ -z "$SCHEMA_FILE" ]]; then
        echo "❌ --reset-schema requires a path to schema file" >&2
        exit 1
      fi
      shift
      ;;
    --update-schema)
      MODE="update-schema"
      shift
      SCHEMA_FILE="$1"
      if [[ -z "$SCHEMA_FILE" ]]; then
        echo "❌ --update-schema requires a path to schema file" >&2
        exit 1
      fi
      shift
      ;;
    *)
      echo "❌ Unknown option: $1" >&2
      echo "Usage: $0 [--reset-db | --reset-schema <file> | --update-schema <file>]" >&2
      exit 1
      ;;
  esac
done

echo "🚀 Starting Now Playing services..."

# Load environment variables from docker/.env file
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
fi

# Service and container names
DB_SERVICE=postgres
DB_CONTAINER=nowplaying-db

# Function to wait for PostgreSQL to be ready
wait_for_postgres() {
  echo "⏳ Waiting for PostgreSQL to be ready..."
  until docker ps --format '{{.Names}}' | grep -q "^${DB_CONTAINER}$"; do
    echo "   ⏳ ${DB_CONTAINER} container not present yet, waiting..."
    sleep 1
  done

  until docker exec ${DB_CONTAINER} pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} > /dev/null 2>&1; do
    sleep 1
  done
  echo "✅ PostgreSQL is ready"
}

# Function to drop all schema objects
drop_schema() {
  echo "🧹 Dropping existing schema..."
  docker exec ${DB_CONTAINER} psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "
    DROP SCHEMA public CASCADE;
    CREATE SCHEMA public;
    GRANT ALL ON SCHEMA public TO ${POSTGRES_USER};
    GRANT ALL ON SCHEMA public TO public;
  " > /dev/null 2>&1
  echo "✅ Schema dropped"
}

# Function to apply schema file
apply_schema() {
  local file=$1
  echo "📋 Applying schema from $file..."
  if [[ ! -f "$file" ]]; then
    echo "❌ Schema file not found: $file" >&2
    exit 1
  fi
  docker exec -i ${DB_CONTAINER} psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} < "$file"
  echo "✅ Schema applied"
}

# Function to display all tables in the database
show_tables() {
  echo ""
  echo "📊 Database Tables:"
  docker exec ${DB_CONTAINER} psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c "
    SELECT 
      schemaname as schema,
      tablename as table_name
    FROM pg_catalog.pg_tables
    WHERE schemaname = 'public'
    ORDER BY tablename;
  " 2>/dev/null || echo "⚠️  Could not retrieve table list"
}

# Execute based on mode
case "$MODE" in
  reset-db)
    echo "🧹 Resetting database (dropping containers/volumes)..."
    ${DC_CMD} down -v || true
    
    echo "📦 Starting fresh PostgreSQL container with INIT_SCHEMA=true..."
    INIT_SCHEMA=true ${DC_CMD} up -d ${DB_SERVICE}
    
    wait_for_postgres
    echo "✅ Database reset complete (schema auto-initialized)"
    ;;
    
  reset-schema)
    echo "📦 Ensuring PostgreSQL is running..."
    ${DC_CMD} up -d ${DB_SERVICE}
    wait_for_postgres
    
    drop_schema
    apply_schema "$SCHEMA_FILE"
    ;;
    
  update-schema)
    echo "📦 Ensuring PostgreSQL is running..."
    ${DC_CMD} up -d ${DB_SERVICE}
    wait_for_postgres
    
    apply_schema "$SCHEMA_FILE"
    ;;
    
  restart)
    echo "📦 Restarting PostgreSQL..."
    ${DC_CMD} restart ${DB_SERVICE} || ${DC_CMD} up -d ${DB_SERVICE}
    wait_for_postgres
    
    # Check if schema exists
    SCHEMA_PRESENT=$(docker exec ${DB_CONTAINER} psql -U ${POSTGRES_USER} -d ${POSTGRES_DB} -tAc "SELECT 1 FROM information_schema.tables WHERE table_name = 'schema_version'" 2>/dev/null || true)
    if [ "$SCHEMA_PRESENT" != "1" ]; then
      echo ""
      echo "⚠️  Schema not found in database"
      echo "To initialize the schema, use one of:"
      echo "  $0 --reset-db"
      echo "  $0 --reset-schema ../database/schema.sql"
      echo ""
    fi
    ;;
esac

echo ""
echo "✅ Services started successfully"
echo ""
echo "📊 Service URLs:"
echo "  PostgreSQL: localhost:5432"
echo "  Database:   nowplaying"
echo "  User:       ${POSTGRES_USER}"
echo ""
echo "Commands:"
echo "  View logs:        ${DC_CMD} logs -f postgres"
echo "  Stop:             ./stop.sh"
echo "  Reset DB:         ./start.sh --reset-db"
echo "  Reset schema:     ./start.sh --reset-schema ../database/schema.sql"
echo "  Update schema:    ./start.sh --update-schema ../database/schema.sql"

# Show tables at the end
show_tables
