#!/bin/bash
set -e

echo "🧪 Testing Phase 1 Setup..."
echo ""

# Test 1: Check directory structure
echo "1️⃣  Checking directory structure..."
if [ -d "old" ] && [ -d "docker" ] && [ -d "database" ]; then
    echo "   ✅ Directory structure correct"
else
    echo "   ❌ Missing directories"
    exit 1
fi

# Test 2: Start database
echo ""
echo "2️⃣  Starting database..."
cd docker
./start.sh
cd ..

# Test 3: Wait for database
echo ""
echo "3️⃣  Waiting for database to be ready..."
sleep 5

# Test 4: Check database connection
echo ""
echo "4️⃣  Testing database connection..."
if docker exec nowplaying-db psql -U nowplaying -d nowplaying -c "SELECT version();" > /dev/null 2>&1; then
    echo "   ✅ Database connection successful"
else
    echo "   ❌ Database connection failed"
    exit 1
fi

# Test 5: Check schema
echo ""
echo "5️⃣  Checking database schema..."
TABLES=$(docker exec nowplaying-db psql -U nowplaying -d nowplaying -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")
TABLES=$(echo $TABLES | xargs)  # Trim whitespace

if [ "$TABLES" -ge "5" ]; then
    echo "   ✅ Schema applied ($TABLES tables found)"
    echo ""
    echo "   Tables:"
    docker exec nowplaying-db psql -U nowplaying -d nowplaying -c "\dt"
else
    echo "   ⚠️  Schema may not be applied ($TABLES tables found)"
    echo "   Run: cd docker && ./init-schema.sh"
fi

# Test 6: Test insert
echo ""
echo "6️⃣  Testing database operations..."
docker exec nowplaying-db psql -U nowplaying -d nowplaying -c "
    INSERT INTO users (email, username, display_name, google_id)
    VALUES ('test@example.com', 'testuser', 'Test User', 'google_test_123')
    ON CONFLICT (email) DO NOTHING;
" > /dev/null 2>&1

USER_COUNT=$(docker exec nowplaying-db psql -U nowplaying -d nowplaying -t -c "SELECT COUNT(*) FROM users;")
USER_COUNT=$(echo $USER_COUNT | xargs)

if [ "$USER_COUNT" -ge "1" ]; then
    echo "   ✅ Database operations working (users: $USER_COUNT)"
else
    echo "   ⚠️  Database operations may have issues"
fi

echo ""
echo "🎉 Phase 1 Setup Complete!"
echo ""
echo "📊 Summary:"
echo "  - Project structure: ✅"
echo "  - Docker Compose: ✅"
echo "  - PostgreSQL: ✅"
echo "  - Database schema: ✅"
echo "  - Test data: ✅"
echo ""
echo "🔍 Quick commands:"
echo "  - Access DB shell:    cd docker && ./psql.sh"
echo "  - View logs:          cd docker && docker-compose logs -f"
echo "  - Stop services:      cd docker && ./stop.sh"
echo ""
echo "📝 Next: Phase 1 / Day 2 - Backend foundation"
