#!/bin/bash
set -e

echo "🛑 Stopping Now Playing services..."

docker-compose down

echo "✅ Services stopped"
