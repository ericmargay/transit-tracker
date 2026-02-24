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
