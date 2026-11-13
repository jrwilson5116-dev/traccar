
#!/usr/bin/env bash

set -e

# Navigate to the directory containing this script
cd "$(dirname "$0")"

echo "======================================"
echo " Traccar Development Environment"
echo "======================================"

echo ""
echo "[1/4] Verifying Docker Compose configuration..."
docker compose config

echo ""
echo "[2/4] Building image and starting container..."
docker compose up -d --build

echo ""
echo "[3/4] Verifying running container..."
docker compose ps

echo ""
echo "[4/4] Entering Traccar development container..."
docker compose exec traccar-dev bash
