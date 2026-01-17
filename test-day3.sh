#!/bin/bash
set -e

echo "🧪 Testing Phase 1 / Day 3 - Google OAuth Implementation"
echo ""

# Ensure we're in the server directory
cd "$(dirname "$0")/server"

# Check if virtual environment exists
if [ ! -d ".venv" ]; then
    echo "📦 Creating virtual environment..."
    python3 -m venv .venv
fi

# Activate virtual environment
echo "🔄 Activating virtual environment..."
source .venv/bin/activate

# Install dependencies
echo "📥 Installing dependencies..."
pip install -q --upgrade pip
pip install -q -r requirements.txt

echo ""
echo "================================================================"
echo "TESTING GOOGLE OAUTH CLIENT"
echo "================================================================"
echo ""

# Test Google OAuth Client
echo "1️⃣  Testing Google OAuth Client (lib/auth/google_oauth.py)..."
python lib/auth/google_oauth.py
if [ $? -eq 0 ]; then
    echo ""
    echo "   ✅ Google OAuth client test passed"
else
    echo ""
    echo "   ❌ Google OAuth client test failed"
    exit 1
fi

echo ""
echo "================================================================"
echo "🎉 Day 3 Tests Passed!"
echo "================================================================"
echo ""
echo "📊 Summary:"
echo "  - Google OAuth Client:  ✅"
echo ""
echo "📝 Next Steps:"
echo "  1. Get Google OAuth credentials from:"
echo "     https://console.cloud.google.com/"
echo ""
echo "  2. Update server/.env with:"
echo "     GOOGLE_CLIENT_ID=your-client-id"
echo "     GOOGLE_CLIENT_SECRET=your-client-secret"
echo "     GOOGLE_REDIRECT_URI=http://localhost:5000/auth/google/callback"
echo ""
echo "  3. Test OAuth flow manually (see output above)"
echo ""
echo "  4. Day 4: Spotify OAuth implementation"
echo ""
