#!/bin/bash
set -e

echo "🧪 Testing Phase 1 / Day 2 - Backend Foundation"
echo ""

# Ensure we're in the server directory
cd "$(dirname "$0")/server"

# Check if virtual environment exists
if [ ! -d ".venv" ]; then
    echo "📦 Creating virtual environment..."
    python -m venv .venv
fi

# Activate virtual environment
echo "🔄 Activating virtual environment..."
source .venv/bin/activate

# Install dependencies
echo "📥 Installing dependencies..."
pip install -q --upgrade pip
pip install -q -r requirements.txt

echo ""
echo "=" * 60
echo "TESTING COMPONENTS"
echo "=" * 60
echo ""

# Test 1: Configuration
echo "1️⃣  Testing Configuration (config.py)..."
python config.py
if [ $? -eq 0 ]; then
    echo "   ✅ Configuration test passed"
else
    echo "   ❌ Configuration test failed"
    exit 1
fi

echo ""

# Test 2: Logger
echo "2️⃣  Testing Logger (lib/utils/logger.py)..."
python lib/utils/logger.py
if [ $? -eq 0 ]; then
    echo "   ✅ Logger test passed"
else
    echo "   ❌ Logger test failed"
    exit 1
fi

echo ""

# Test 3: Database
echo "3️⃣  Testing Database Connection (lib/database.py)..."
python lib/database.py
if [ $? -eq 0 ]; then
    echo "   ✅ Database test passed"
else
    echo "   ❌ Database test failed"
    exit 1
fi

echo ""
echo "=" * 60
echo "🎉 All Day 2 Tests Passed!"
echo "=" * 60
echo ""
echo "📊 Summary:"
echo "  - Configuration:  ✅"
echo "  - Logging:        ✅"
echo "  - Database:       ✅"
echo ""
echo "📝 Next Steps:"
echo "  - Day 3: Google OAuth implementation"
echo "  - Day 4: Spotify OAuth implementation"
echo "  - Day 5: Authentication manager & JWT"
echo "  - Day 6: Flask application with API routes"
echo ""
