#!/usr/bin/env bash
# ============================================================
#  CDMX Transit Tracker — Web App Project Structure Setup
#  Run from the root of your cdmx-transit-tracker repo
#  while already on the web-app branch.
# ============================================================

set -e  # exit on any error

echo "🚇 Setting up CDMX Transit Tracker web project structure..."

# ── 1. Backend ───────────────────────────────────────────────
echo "\n📁 Creating directory structure..."

mkdir -p web/backend/app/routers
mkdir -p web/backend/app/websocket
mkdir -p web/backend/app/models
mkdir -p web/backend/app/ml
mkdir -p web/backend/app/tasks
mkdir -p web/backend/alembic

# ── 2. Frontend ──────────────────────────────────────────────
mkdir -p web/frontend/src/components/Map
mkdir -p web/frontend/src/components/LineSelector
mkdir -p web/frontend/src/components/VehicleLayer
mkdir -p web/frontend/src/components/PredictionLayer
mkdir -p web/frontend/src/components/ContributeButton
mkdir -p web/frontend/src/hooks
mkdir -p web/frontend/src/services
mkdir -p web/frontend/src/types
mkdir -p web/frontend/src/data
mkdir -p web/frontend/public/geojson

# ── 3. Data / scripts ────────────────────────────────────────
mkdir -p Data/routes
mkdir -p Data/scripts

# ── 4. Docs ──────────────────────────────────────────────────
mkdir -p docs

# ── 5. Backend placeholder files ─────────────────────────────
echo "\n📝 Creating backend placeholder files..."

touch web/backend/app/__init__.py
touch web/backend/app/config.py
touch web/backend/app/main.py
touch web/backend/app/routers/__init__.py
touch web/backend/app/routers/lines.py
touch web/backend/app/routers/vehicles.py
touch web/backend/app/routers/predictions.py
touch web/backend/app/websocket/__init__.py
touch web/backend/app/websocket/hub.py
touch web/backend/app/models/__init__.py
touch web/backend/app/models/database.py
touch web/backend/app/models/schemas.py
touch web/backend/app/ml/__init__.py
touch web/backend/app/ml/features.py
touch web/backend/app/ml/trainer.py
touch web/backend/app/ml/predictor.py
touch web/backend/app/ml/pipeline.py
touch web/backend/app/tasks/__init__.py
touch web/backend/app/tasks/aggregator.py
touch web/backend/Dockerfile
touch web/backend/requirements.txt

# ── 6. Frontend placeholder files ────────────────────────────
echo "\n📝 Creating frontend placeholder files..."

touch web/frontend/src/App.tsx
touch web/frontend/src/main.tsx
touch web/frontend/src/hooks/useGeolocation.ts
touch web/frontend/src/hooks/useWebSocket.ts
touch web/frontend/src/hooks/useLiveVehicles.ts
touch web/frontend/src/services/api.ts
touch web/frontend/src/services/websocket.ts
touch web/frontend/src/types/transit.ts
touch web/frontend/src/data/lineRegistry.ts
touch web/frontend/index.html
touch web/frontend/vite.config.ts
touch web/frontend/tsconfig.json
touch web/frontend/package.json

# ── 7. Data scripts ───────────────────────────────────────────
touch Data/scripts/normalize_geojson.py

# ── 8. Docker Compose + env ──────────────────────────────────
echo "\n🐳 Creating Docker and env files..."

touch web/docker-compose.yml

cat > web/.env.example << 'ENVEOF'
MAPBOX_TOKEN=pk.YOUR_PUBLIC_TOKEN_HERE
POSTGRES_DB=transit_tracker
POSTGRES_USER=transit
POSTGRES_PASSWORD=transit_dev
DATABASE_URL=postgresql+asyncpg://transit:transit_dev@db:5432/transit_tracker
ENVEOF

# ── 9. .gitignore additions ──────────────────────────────────
echo "\n🔒 Updating .gitignore..."

cat >> .gitignore << 'IGNEOF'

# Web app
web/.env
web/frontend/node_modules/
web/frontend/dist/
web/frontend/.vite/
web/backend/__pycache__/
web/backend/**/__pycache__/
web/backend/*.pyc
web/backend/.venv/

# ML models (large binary files)
*.joblib
*.pkl
IGNEOF

# ── 10. README skeleton ───────────────────────────────────────
echo "\n📄 Creating README..."

cat > web/README.md << 'READMEEOF'
# CDMX Transit Tracker — Web App

Real-time crowdsourced vehicle tracking for Mexico City Metro and Metrobus.

## Stack
- **Frontend**: React + TypeScript + Vite + Mapbox GL JS
- **Backend**: FastAPI + WebSockets + PostgreSQL/PostGIS
- **ML**: LightGBM (arrival time, crowding) + Isolation Forest (anomaly detection)
- **Infra**: Docker Compose

## Quick Start

```bash
# 1. Copy and fill in your tokens
cp .env.example .env

# 2. Copy GeoJSON data
cp ../Data/routes/metro_lines.geojson frontend/public/geojson/
cp ../Data/routes/metro_stops.geojson frontend/public/geojson/

# 3. Start everything
docker compose up --build
```

Frontend: http://localhost:5173
Backend API: http://localhost:8001
API Docs: http://localhost:8001/docs
READMEEOF

# ── 11. Verify structure ──────────────────────────────────────
echo "\n✅ Structure created. Full file tree:\n"
find web Data docs -type f | sort

echo "\n🎉 Done! Paste your code into the files above."
echo "   Next: cp web/.env.example web/.env  ->  fill in tokens  ->  docker compose up --build"
