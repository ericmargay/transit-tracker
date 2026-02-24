#!/usr/bin/env bash
# ============================================================
#  CDMX Transit Tracker — Core system build
#  1. Metrobús GeoJSON download
#  2. Vehicle clustering on backend
#  3. 500-user simulation
#  4. Clean map-only frontend
#  Run from: web/
# ============================================================
set -e

echo "🚇 Building CDMX Transit Tracker core system..."

# ── 1. UPDATE GEOJSON DOWNLOADER (adds Metrobús) ─────────────────────────
cat > download_geojson.sh << 'DLEOF'
#!/usr/bin/env bash
set -e
TARGET_DIR="${1:-frontend/public/geojson}"
RAW_DIR="${TARGET_DIR}/raw"
SCRIPTS_DIR="../../Data/scripts"

echo "🚇 Downloading CDMX transit data from OpenStreetMap..."
mkdir -p "$TARGET_DIR" "$RAW_DIR" "$SCRIPTS_DIR"

# Metro lines
echo "⬇️  Metro lines..."
curl -s --max-time 90 -G "https://overpass-api.de/api/interpreter" \
  --data-urlencode 'data=[out:json][timeout:60];relation["network"="STC Metro"]["type"="route"]["route"="subway"](19.2,-99.4,19.7,-98.9);(._;>;);out geom;' \
  -o "$RAW_DIR/metro_lines_raw.json"
echo "   $(wc -c < $RAW_DIR/metro_lines_raw.json | tr -d ' ') bytes"

# Metro stops
echo "⬇️  Metro stops..."
curl -s --max-time 90 -G "https://overpass-api.de/api/interpreter" \
  --data-urlencode 'data=[out:json][timeout:60];node["station"="subway"]["network"="STC Metro"](19.2,-99.4,19.7,-98.9);out geom;' \
  -o "$RAW_DIR/metro_stops_raw.json"
echo "   $(wc -c < $RAW_DIR/metro_stops_raw.json | tr -d ' ') bytes"

# Metrobús lines
echo "⬇️  Metrobús lines..."
curl -s --max-time 90 -G "https://overpass-api.de/api/interpreter" \
  --data-urlencode 'data=[out:json][timeout:60];relation["network"="Metrobús"]["type"="route"]["route"="bus"](19.2,-99.4,19.7,-98.9);(._;>;);out geom;' \
  -o "$RAW_DIR/metrobus_lines_raw.json"
MB_SIZE=$(wc -c < "$RAW_DIR/metrobus_lines_raw.json" | tr -d ' ')
echo "   $MB_SIZE bytes"
if [ "$MB_SIZE" -lt 100 ]; then
  echo "   ⚠️  Retrying with operator tag..."
  curl -s --max-time 90 -G "https://overpass-api.de/api/interpreter" \
    --data-urlencode 'data=[out:json][timeout:60];relation["operator"="Metrobús"]["type"="route"](19.2,-99.4,19.7,-98.9);(._;>;);out geom;' \
    -o "$RAW_DIR/metrobus_lines_raw.json"
  echo "   $(wc -c < $RAW_DIR/metrobus_lines_raw.json | tr -d ' ') bytes"
fi

# Metrobús stops
echo "⬇️  Metrobús stops..."
curl -s --max-time 90 -G "https://overpass-api.de/api/interpreter" \
  --data-urlencode 'data=[out:json][timeout:60];node["network"="Metrobús"]["highway"="bus_stop"](19.2,-99.4,19.7,-98.9);out geom;' \
  -o "$RAW_DIR/metrobus_stops_raw.json"
echo "   $(wc -c < $RAW_DIR/metrobus_stops_raw.json | tr -d ' ') bytes"

# Normalizer
cat > "$SCRIPTS_DIR/normalize_geojson.py" << 'PYEOF'
import json, sys, os, re

METRO_CONFIG = {
    "1":  {"color":"#E91E8C","name":"Línea 1","id":"metro-1"},
    "2":  {"color":"#1565C0","name":"Línea 2","id":"metro-2"},
    "3":  {"color":"#6A1B9A","name":"Línea 3","id":"metro-3"},
    "4":  {"color":"#00838F","name":"Línea 4","id":"metro-4"},
    "5":  {"color":"#FDD835","name":"Línea 5","id":"metro-5"},
    "6":  {"color":"#E53935","name":"Línea 6","id":"metro-6"},
    "7":  {"color":"#FB8C00","name":"Línea 7","id":"metro-7"},
    "8":  {"color":"#558B2F","name":"Línea 8","id":"metro-8"},
    "9":  {"color":"#4E342E","name":"Línea 9","id":"metro-9"},
    "A":  {"color":"#8D6E63","name":"Línea A","id":"metro-a"},
    "B":  {"color":"#90A4AE","name":"Línea B","id":"metro-b"},
    "12": {"color":"#F9A825","name":"Línea 12","id":"metro-12"},
}

METROBUS_CONFIG = {
    "1": {"color":"#E53935","name":"Línea 1","id":"metrobus-1"},
    "2": {"color":"#1565C0","name":"Línea 2","id":"metrobus-2"},
    "3": {"color":"#2E7D32","name":"Línea 3","id":"metrobus-3"},
    "4": {"color":"#6A1B9A","name":"Línea 4","id":"metrobus-4"},
    "5": {"color":"#F57F17","name":"Línea 5","id":"metrobus-5"},
    "6": {"color":"#00838F","name":"Línea 6","id":"metrobus-6"},
    "7": {"color":"#AD1457","name":"Línea 7","id":"metrobus-7"},
}

def norm_ref(raw, config):
    if not raw: return None
    s = re.sub(r'(?:l[ií]nea|línea|line|metrobús|metrobus)\s*', '', raw.strip(), flags=re.IGNORECASE).strip().upper()
    s = re.sub(r'^L(?=[0-9AB])', '', s)
    return s if s in config else None

def process_lines(raw_path, out_path, config):
    with open(raw_path) as f: data = json.load(f)
    elements = data.get("elements", [])
    print(f"  {os.path.basename(raw_path)}: {len(elements)} elements")
    features, seen = [], set()
    for el in elements:
        if el.get("type") != "relation": continue
        tags = el.get("tags", {})
        ref = norm_ref(tags.get("ref") or tags.get("name",""), config)
        if not ref:
            for field in ["ref","name","description"]:
                m = re.search(r'(\d{1,2}|[AB])\b', tags.get(field,""))
                if m:
                    ref = m.group(1).upper()
                    if ref in config: break
        cfg = config.get(ref)
        if not cfg: continue
        key = f"{cfg['id']}-{el['id']}"
        if key in seen: continue
        seen.add(key)
        for member in el.get("members", []):
            if member.get("type") != "way" or "geometry" not in member: continue
            coords = [[pt["lon"], pt["lat"]] for pt in member["geometry"]]
            if len(coords) >= 2:
                features.append({"type":"Feature",
                    "geometry":{"type":"LineString","coordinates":coords},
                    "properties":{"line_id":cfg["id"],"line_name":cfg["name"],"line_color":cfg["color"]}})
    print(f"  → {len(features)} segments")
    with open(out_path,"w") as f:
        json.dump({"type":"FeatureCollection","features":features},f,ensure_ascii=False,indent=2)

def process_stops(raw_path, out_path, config, id_prefix):
    with open(raw_path) as f: data = json.load(f)
    elements = data.get("elements", [])
    print(f"  {os.path.basename(raw_path)}: {len(elements)} elements")
    features, seen = [], set()
    for el in elements:
        if el.get("type") != "node": continue
        tags = el.get("tags", {})
        name = (tags.get("name") or "").strip()
        if not name: continue
        ref = norm_ref(tags.get("ref") or tags.get("line",""), config)
        cfg = config.get(ref) if ref else None
        line_id    = cfg["id"]    if cfg else f"{id_prefix}-unknown"
        line_color = cfg["color"] if cfg else "#ffffff"
        key = f"{name}|{line_id}"
        if key in seen: continue
        seen.add(key)
        slug = name.lower().replace(" ","-").replace("/","-")
        features.append({"type":"Feature",
            "geometry":{"type":"Point","coordinates":[el["lon"],el["lat"]]},
            "properties":{"stop_id":f"{line_id}-{slug}","stop_name":name,
                         "line_id":line_id,"line_color":line_color,
                         "is_transfer":tags.get("transfer","no")=="yes"}})
    print(f"  → {len(features)} stops")
    with open(out_path,"w") as f:
        json.dump({"type":"FeatureCollection","features":features},f,ensure_ascii=False,indent=2)

if __name__ == "__main__":
    base = sys.argv[1] if len(sys.argv) > 1 else "."
    raw  = os.path.join(base, "raw")
    process_lines(os.path.join(raw,"metro_lines_raw.json"),    os.path.join(base,"metro_lines.geojson"),    METRO_CONFIG)
    process_stops(os.path.join(raw,"metro_stops_raw.json"),    os.path.join(base,"metro_stops.geojson"),    METRO_CONFIG, "metro")
    process_lines(os.path.join(raw,"metrobus_lines_raw.json"), os.path.join(base,"metrobus_lines.geojson"), METROBUS_CONFIG)
    process_stops(os.path.join(raw,"metrobus_stops_raw.json"), os.path.join(base,"metrobus_stops.geojson"), METROBUS_CONFIG, "metrobus")
    print("\n✅ GeoJSON ready!")
PYEOF

echo "\n⚙️  Normalizing..."
python3 "$SCRIPTS_DIR/normalize_geojson.py" "$TARGET_DIR"

mkdir -p "../../Data/routes"
for f in metro_lines metro_stops metrobus_lines metrobus_stops; do
  cp "$TARGET_DIR/${f}.geojson" "../../Data/routes/${f}.geojson" 2>/dev/null && echo "  ✓ $f.geojson"
done

ML=$(python3 -c "import json;d=json.load(open('$TARGET_DIR/metro_lines.geojson'));print(len(d['features']))")
MS=$(python3 -c "import json;d=json.load(open('$TARGET_DIR/metro_stops.geojson'));print(len(d['features']))")
BL=$(python3 -c "import json;d=json.load(open('$TARGET_DIR/metrobus_lines.geojson'));print(len(d['features']))")
BS=$(python3 -c "import json;d=json.load(open('$TARGET_DIR/metrobus_stops.geojson'));print(len(d['features']))")
echo "\n✅ Metro: $ML segments, $MS stops | Metrobús: $BL segments, $BS stops"
DLEOF
chmod +x download_geojson.sh
echo "  ✓ download_geojson.sh"

# ── 2. VEHICLE CLUSTERING (backend aggregation) ───────────────────────────
cat > backend/app/routers/vehicles.py << 'EOF'
from fastapi import APIRouter, Depends, WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy import text
from datetime import datetime, timedelta, UTC
from math import radians, sin, cos, sqrt, atan2
import json

from app.models.database import get_db, VehicleReport
from app.models.schemas import VehicleReportCreate, WSMessage, WSMessageType
from app.websocket.hub import hub

router = APIRouter(prefix="/vehicles", tags=["vehicles"])

CLUSTER_RADIUS_M = 400   # reports within 400m = same vehicle
WINDOW_MINUTES   = 3     # only use recent reports


def haversine_m(lat1, lon1, lat2, lon2) -> float:
    R = 6_371_000
    φ1, φ2 = radians(lat1), radians(lat2)
    dφ = radians(lat2 - lat1)
    dλ = radians(lon2 - lon1)
    a = sin(dφ/2)**2 + cos(φ1)*cos(φ2)*sin(dλ/2)**2
    return R * 2 * atan2(sqrt(a), sqrt(1-a))


def cluster_reports(rows) -> list[dict]:
    """Single-linkage clustering by position → one dict per vehicle cluster."""
    points = [{"lat": r.lat, "lon": r.lon, "heading": r.heading,
               "speed": r.speed, "crowding": r.crowding, "count": 1}
              for r in rows if r.lat is not None]
    if not points:
        return []

    clusters: list[list[dict]] = []
    assigned = [False] * len(points)

    for i, p in enumerate(points):
        if assigned[i]:
            continue
        cluster = [p]
        assigned[i] = True
        for j, q in enumerate(points):
            if assigned[j]:
                continue
            if haversine_m(p["lat"], p["lon"], q["lat"], q["lon"]) <= CLUSTER_RADIUS_M:
                cluster.append(q)
                assigned[j] = True
        clusters.append(cluster)

    vehicles = []
    for cl in clusters:
        n = len(cl)
        lats   = [p["lat"]  for p in cl]
        lons   = [p["lon"]  for p in cl]
        heads  = [p["heading"] for p in cl if p["heading"] is not None]
        speeds = [p["speed"]   for p in cl if p["speed"]   is not None]
        crowds = [p["crowding"] for p in cl if p["crowding"]]
        vehicles.append({
            "latitude":     sum(lats)/n,
            "longitude":    sum(lons)/n,
            "heading":      sum(heads)/len(heads) if heads else None,
            "speed_ms":     sum(speeds)/len(speeds) if speeds else None,
            "crowding":     max(set(crowds), key=crowds.count) if crowds else None,
            "report_count": n,
        })
    return vehicles


@router.post("/report")
async def submit_report(report: VehicleReportCreate, db: AsyncSession = Depends(get_db)):
    db_report = VehicleReport(
        line_id    = report.line_id,
        session_id = report.session_id,
        latitude   = report.latitude,
        longitude  = report.longitude,
        heading    = report.heading,
        speed_ms   = report.speed_ms,
        crowding   = report.crowding.value if report.crowding else None,
    )
    db.add(db_report)
    await db.commit()
    await aggregate_and_broadcast(report.line_id, db)
    return {"status": "ok"}


@router.get("/{line_id}")
async def get_vehicles(line_id: str, db: AsyncSession = Depends(get_db)):
    rows = await _fetch_recent(line_id, db)
    return cluster_reports(rows)


@router.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await hub.connect(websocket)
    try:
        while True:
            raw = await websocket.receive_text()
            msg = WSMessage(**json.loads(raw))
            if msg.type == WSMessageType.subscribe:
                await hub.subscribe(websocket, msg.payload["line_id"])
            elif msg.type == WSMessageType.unsubscribe:
                await hub.unsubscribe(websocket, msg.payload["line_id"])
    except WebSocketDisconnect:
        await hub.disconnect(websocket)


async def _fetch_recent(line_id: str, db: AsyncSession):
    cutoff = datetime.now(UTC) - timedelta(minutes=WINDOW_MINUTES)
    result = await db.execute(
        text("""
            SELECT latitude AS lat, longitude AS lon,
                   heading, speed_ms AS speed, crowding
            FROM vehicle_reports
            WHERE line_id = :line_id AND reported_at > :cutoff
        """),
        {"line_id": line_id, "cutoff": cutoff}
    )
    return result.fetchall()


async def aggregate_and_broadcast(line_id: str, db: AsyncSession):
    rows     = await _fetch_recent(line_id, db)
    vehicles = cluster_reports(rows)
    if vehicles:
        await hub.broadcast_to_line(line_id, {
            "type": "vehicle_update",
            "payload": {
                "lineId":   line_id,
                "vehicles": vehicles,
                "updatedAt": datetime.now(UTC).isoformat(),
            }
        })
EOF
echo "  ✓ backend/app/routers/vehicles.py (with clustering)"

# ── 3. SIMULATION ENGINE ──────────────────────────────────────────────────
cat > backend/app/tasks/simulation.py << 'EOF'
"""
500-user natural movement simulation.
- Loads line geometries from GeoJSON files
- Creates realistic wagon objects that move along routes
- Each wagon has 3–8 phantom reporters with GPS noise
- Reports are inserted via the normal DB pathway and broadcast over WS
"""

import asyncio, json, math, random, logging
from pathlib import Path
from datetime import datetime, UTC

logger = logging.getLogger(__name__)

GEOJSON_DIR = Path(__file__).parent.parent.parent / "frontend" / "public" / "geojson"
REPORT_INTERVAL  = 8      # seconds between GPS reports
NOISE_M          = 15     # GPS noise radius in metres
METRO_SPEED_MS   = 9.5    # ~34 km/h average metro speed
BUS_SPEED_MS     = 5.5    # ~20 km/h average bus speed
HEADWAY_S        = 180    # seconds between wagons on same line


def haversine_m(lat1, lon1, lat2, lon2) -> float:
    R = 6_371_000
    φ1, φ2 = math.radians(lat1), math.radians(lat2)
    dφ = math.radians(lat2 - lat1)
    dλ = math.radians(lon2 - lon1)
    a  = math.sin(dφ/2)**2 + math.cos(φ1)*math.cos(φ2)*math.sin(dλ/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))


def bearing(lat1, lon1, lat2, lon2) -> float:
    φ1, φ2 = math.radians(lat1), math.radians(lat2)
    dλ = math.radians(lon2 - lon1)
    x  = math.sin(dλ) * math.cos(φ2)
    y  = math.cos(φ1)*math.sin(φ2) - math.sin(φ1)*math.cos(φ2)*math.cos(dλ)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def add_noise(lat, lon, radius_m=NOISE_M):
    r     = radius_m / 111_320
    angle = random.uniform(0, 2*math.pi)
    return lat + r*math.sin(angle), lon + r*math.cos(angle)


def build_route(features: list) -> list[tuple[float,float]]:
    """Merge all LineString segments into one ordered coordinate list."""
    if not features:
        return []
    # Collect all coords from all segments
    all_segs = []
    for f in features:
        geom = f.get("geometry", {})
        if geom.get("type") == "LineString":
            all_segs.append(f["geometry"]["coordinates"])
    if not all_segs:
        return []
    # Try to chain segments end-to-end
    result = list(all_segs[0])
    for seg in all_segs[1:]:
        if not seg:
            continue
        # Check if we should append forward or reversed
        d_ff = haversine_m(result[-1][1], result[-1][0], seg[0][1],  seg[0][0])
        d_fr = haversine_m(result[-1][1], result[-1][0], seg[-1][1], seg[-1][0])
        if d_fr < d_ff:
            seg = list(reversed(seg))
        # Only append if reasonably close (< 2km gap)
        if haversine_m(result[-1][1], result[-1][0], seg[0][1], seg[0][0]) < 2000:
            result.extend(seg[1:])
        else:
            result.extend(seg)
    return [(c[1], c[0]) for c in result]   # → (lat, lon)


def sample_route_at_distance(route, distance_m):
    """Return (lat, lon, heading) at `distance_m` along the route."""
    walked = 0.0
    for i in range(len(route)-1):
        seg_len = haversine_m(*route[i], *route[i+1])
        if walked + seg_len >= distance_m:
            frac = (distance_m - walked) / max(seg_len, 0.001)
            lat  = route[i][0] + frac * (route[i+1][0] - route[i][0])
            lon  = route[i][1] + frac * (route[i+1][1] - route[i][1])
            hdg  = bearing(*route[i], *route[i+1])
            return lat, lon, hdg
        walked += seg_len
    return route[-1][0], route[-1][1], 0.0


def route_length(route) -> float:
    return sum(haversine_m(*route[i], *route[i+1]) for i in range(len(route)-1))


class SimWagon:
    def __init__(self, line_id, route, speed_ms, offset_m, direction):
        self.line_id   = line_id
        self.route     = route
        self.speed_ms  = speed_ms * random.uniform(0.85, 1.15)
        self.position  = offset_m % route_length(route)
        self.direction = direction   # +1 or -1
        self.length    = route_length(route)
        self.reporters = random.randint(3, 8)

    def step(self, dt_s):
        self.position += self.speed_ms * self.direction * dt_s
        if self.position >= self.length:
            self.position = self.length - (self.position - self.length)
            self.direction = -1
        elif self.position <= 0:
            self.position = abs(self.position)
            self.direction = 1

    def get_reports(self):
        route = self.route if self.direction == 1 else list(reversed(self.route))
        pos   = self.position if self.direction == 1 else self.length - self.position
        lat, lon, hdg = sample_route_at_distance(route, pos)
        reports = []
        for _ in range(self.reporters):
            nlat, nlon = add_noise(lat, lon)
            reports.append({
                "line_id":    self.line_id,
                "latitude":   nlat,
                "longitude":  nlon,
                "heading":    hdg + random.gauss(0, 5),
                "speed_ms":   self.speed_ms + random.gauss(0, 0.5),
                "crowding":   random.choice(["empty","light","moderate","packed",None]),
                "session_id": f"sim-{self.line_id}-{id(self)}-{_}",
            })
        return reports


def load_lines() -> dict[str, list]:
    wagons = []
    for geojson_file in GEOJSON_DIR.glob("*_lines.geojson"):
        system = "metro" if "metro_lines" in geojson_file.name else "metrobus"
        speed  = METRO_SPEED_MS if system == "metro" else BUS_SPEED_MS
        try:
            data     = json.loads(geojson_file.read_text())
            features = data.get("features", [])
        except Exception as e:
            logger.warning(f"Cannot load {geojson_file}: {e}")
            continue

        # Group features by line_id
        by_line: dict[str, list] = {}
        for f in features:
            lid = f.get("properties", {}).get("line_id", "unknown")
            by_line.setdefault(lid, []).append(f)

        for line_id, feats in by_line.items():
            route = build_route(feats)
            if len(route) < 2:
                continue
            length  = route_length(route)
            # Space wagons ~headway_s * speed_ms apart
            spacing = HEADWAY_S * speed
            n_wagons = max(2, int(length / spacing))
            logger.info(f"  {line_id}: {len(route)} pts, {length/1000:.1f}km, {n_wagons} wagons")
            for i in range(n_wagons):
                offset = (i * spacing) % length
                direction = random.choice([1, -1])
                wagons.append(SimWagon(line_id, route, speed, offset, direction))

    return wagons


async def run_simulation(db_factory):
    """Background task: step all wagons and insert reports every REPORT_INTERVAL s."""
    logger.info("🚇 Loading simulation routes...")
    wagons = load_lines()
    if not wagons:
        logger.warning("No routes loaded — run ./download_geojson.sh first")
        return

    total_reporters = sum(w.reporters for w in wagons)
    logger.info(f"🚇 Simulation started: {len(wagons)} wagons, ~{total_reporters} reporters")

    from sqlalchemy import text as sa_text
    from app.routers.vehicles import aggregate_and_broadcast

    while True:
        start = asyncio.get_event_loop().time()

        # Step all wagons
        for w in wagons:
            w.step(REPORT_INTERVAL)

        # Collect all reports
        all_reports = []
        for w in wagons:
            all_reports.extend(w.get_reports())

        # Bulk insert
        if all_reports:
            async with db_factory() as db:
                await db.execute(
                    sa_text("""
                        INSERT INTO vehicle_reports
                            (id, line_id, session_id, latitude, longitude,
                             heading, speed_ms, crowding, reported_at)
                        VALUES
                            (gen_random_uuid(), :line_id, :session_id,
                             :latitude, :longitude, :heading, :speed_ms,
                             :crowding, NOW())
                    """),
                    all_reports
                )
                await db.commit()

                # Broadcast aggregated vehicles for each line
                line_ids = list({r["line_id"] for r in all_reports})
                for line_id in line_ids:
                    await aggregate_and_broadcast(line_id, db)

        elapsed = asyncio.get_event_loop().time() - start
        sleep_s = max(0.1, REPORT_INTERVAL - elapsed)
        await asyncio.sleep(sleep_s)
EOF
echo "  ✓ backend/app/tasks/simulation.py"

# ── 4. MAIN.PY (starts simulation) ───────────────────────────────────────
cat > backend/app/main.py << 'EOF'
import asyncio, logging
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager

from app.models.database import create_tables, AsyncSessionLocal
from app.routers.vehicles import router as vehicles_router
from app.routers.lines import router as lines_router
from app.tasks.simulation import run_simulation

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await create_tables()
    sim_task = asyncio.create_task(run_simulation(AsyncSessionLocal))
    yield
    sim_task.cancel()
    try:
        await sim_task
    except asyncio.CancelledError:
        pass


app = FastAPI(title="CDMX Transit Tracker", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
app.include_router(vehicles_router)
app.include_router(lines_router)


@app.get("/health")
async def health():
    return {"status": "ok"}
EOF
echo "  ✓ backend/app/main.py"

# ── 5. CLEAN MAP FRONTEND (no chrome) ────────────────────────────────────
cat > frontend/src/App.tsx << 'APPEOF'
/**
 * CDMX Transit Tracker — clean map view
 * Shows Metro + Metrobús lines, stops, and real-time vehicle clusters.
 * No UI chrome — just the map.
 */
import { useEffect, useRef, useCallback, useState } from 'react'
import mapboxgl from 'mapbox-gl'
import 'mapbox-gl/dist/mapbox-gl.css'
import { lineById } from './data/lineRegistry'

mapboxgl.accessToken = import.meta.env.VITE_MAPBOX_TOKEN ?? ''

const WS_URL = (import.meta.env.VITE_WS_URL ?? 'ws://localhost:8001') + '/vehicles/ws'
const ALL_LINE_IDS = [
  'metro-1','metro-2','metro-3','metro-4','metro-5','metro-6',
  'metro-7','metro-8','metro-9','metro-a','metro-b','metro-12',
  'metrobus-1','metrobus-2','metrobus-3','metrobus-4',
  'metrobus-5','metrobus-6','metrobus-7',
]

type VehicleCluster = {
  latitude: number; longitude: number
  heading: number | null; speed_ms: number | null
  crowding: string | null; report_count: number
}

type WSPayload = {
  lineId: string; vehicles: VehicleCluster[]; updatedAt: string
}

// Per-line vehicle state: lineId → list of clusters
type VehicleState = Record<string, VehicleCluster[]>

export default function App() {
  const containerRef = useRef<HTMLDivElement>(null)
  const map          = useRef<mapboxgl.Map | null>(null)
  const ws           = useRef<WebSocket | null>(null)
  const vehicles     = useRef<VehicleState>({})
  const [ready, setReady] = useState(false)

  // ── init map ────────────────────────────────────────────────────────────
  useEffect(() => {
    if (map.current || !containerRef.current) return
    map.current = new mapboxgl.Map({
      container: containerRef.current,
      style: 'mapbox://styles/mapbox/dark-v11',
      center: [-99.1332, 19.4326],
      zoom: 11.2,
      attributionControl: false,
    })
    map.current.addControl(new mapboxgl.AttributionControl({ compact: true }), 'bottom-right')
    map.current.on('load', () => {
      initLayers(map.current!)
      setReady(true)
    })
    return () => { map.current?.remove(); map.current = null }
  }, [])

  // ── load GeoJSON layers ─────────────────────────────────────────────────
  const initLayers = useCallback(async (m: mapboxgl.Map) => {
    const load = async (url: string) => {
      const r = await fetch(url)
      if (!r.ok) throw new Error(`${url} → ${r.status}`)
      return r.json()
    }

    try {
      const [metroLines, metroStops, mbLines, mbStops] = await Promise.all([
        load('/geojson/metro_lines.geojson'),
        load('/geojson/metro_stops.geojson'),
        load('/geojson/metrobus_lines.geojson'),
        load('/geojson/metrobus_stops.geojson'),
      ])

      // ── line layers (casing + color) ─────────────────────────────────
      for (const [srcId, data, width] of [
        ['metro-lines',    metroLines, 4],
        ['metrobus-lines', mbLines,    3],
      ] as [string, GeoJSON.FeatureCollection, number][]) {
        m.addSource(srcId, { type: 'geojson', data })
        m.addLayer({ id: `${srcId}-casing`, type: 'line', source: srcId,
          paint: { 'line-color': '#000', 'line-width': width + 3, 'line-opacity': 0.5, 'line-cap': 'round', 'line-join': 'round' } })
        m.addLayer({ id: `${srcId}-fill`, type: 'line', source: srcId,
          paint: { 'line-color': ['get','line_color'], 'line-width': width, 'line-opacity': 0.95, 'line-cap': 'round', 'line-join': 'round' } })
      }

      // ── stop layers ──────────────────────────────────────────────────
      for (const [srcId, data] of [
        ['metro-stops',    metroStops],
        ['metrobus-stops', mbStops],
      ] as [string, GeoJSON.FeatureCollection][]) {
        m.addSource(srcId, { type: 'geojson', data })
        m.addLayer({ id: `${srcId}-circle`, type: 'circle', source: srcId,
          paint: {
            'circle-color': '#fff',
            'circle-radius': ['interpolate',['linear'],['zoom'],10,2,15,6],
            'circle-stroke-color': ['get','line_color'],
            'circle-stroke-width': ['interpolate',['linear'],['zoom'],10,1,15,3],
          }
        })
        m.addLayer({ id: `${srcId}-label`, type: 'symbol', source: srcId, minzoom: 13,
          layout: {
            'text-field': ['get','stop_name'],
            'text-size': 10,
            'text-offset': [0, 1.4],
            'text-anchor': 'top',
            'text-optional': true,
          },
          paint: { 'text-color': '#fff', 'text-halo-color': '#000', 'text-halo-width': 1.2 }
        })
        m.on('mouseenter', `${srcId}-circle`, () => m.getCanvas().style.cursor = 'pointer')
        m.on('mouseleave', `${srcId}-circle`, () => m.getCanvas().style.cursor = '')
        m.on('click', `${srcId}-circle`, (e) => {
          const props = e.features?.[0]?.properties as Record<string, string> | undefined
          if (!props) return
          const line = lineById(props.line_id)
          new mapboxgl.Popup({ closeButton: false, offset: 8 })
            .setLngLat(e.lngLat)
            .setHTML(`
              <div style="font:13px/1.4 system-ui;padding:4px 6px">
                <span style="background:${line?.colorHex ?? '#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName ?? ''}</span>
                <div style="font-weight:600;margin-top:5px">${props.stop_name}</div>
              </div>`)
            .addTo(m)
        })
      }

      // ── vehicle layer (pulsing ring + dot) ───────────────────────────
      m.addSource('vehicles', {
        type: 'geojson',
        data: { type: 'FeatureCollection', features: [] },
      })
      // Outer glow
      m.addLayer({ id: 'vehicle-glow', type: 'circle', source: 'vehicles',
        paint: {
          'circle-radius':  ['interpolate',['linear'],['zoom'],10,16,15,28],
          'circle-color':   ['get','line_color'],
          'circle-opacity': 0.18,
        }
      })
      // Core dot
      m.addLayer({ id: 'vehicle-dot', type: 'circle', source: 'vehicles',
        paint: {
          'circle-radius':       ['interpolate',['linear'],['zoom'],10,6,15,12],
          'circle-color':        ['get','line_color'],
          'circle-stroke-color': '#fff',
          'circle-stroke-width': 2,
          'circle-opacity': [
            'case', ['get','is_estimate'], 0.65, 1.0
          ],
        }
      })
      // Reporter count badge
      m.addLayer({ id: 'vehicle-label', type: 'symbol', source: 'vehicles',
        layout: {
          'text-field': ['to-string', ['get','report_count']],
          'text-size':  10,
          'text-font':  ['DIN Offc Pro Bold','Arial Unicode MS Bold'],
        },
        paint: { 'text-color': '#fff' }
      })

    } catch (err) {
      console.warn('GeoJSON load error:', err)
    }
  }, [])

  // ── update vehicle source ───────────────────────────────────────────────
  const updateVehicleLayer = useCallback(() => {
    if (!map.current || !map.current.getSource('vehicles')) return
    const src = map.current.getSource('vehicles') as mapboxgl.GeoJSONSource
    const features: GeoJSON.Feature[] = []

    for (const [lineId, clusters] of Object.entries(vehicles.current)) {
      const line = lineById(lineId)
      for (const v of clusters) {
        features.push({
          type: 'Feature',
          geometry: { type: 'Point', coordinates: [v.longitude, v.latitude] },
          properties: {
            line_id:      lineId,
            line_color:   line?.colorHex ?? '#ffffff',
            heading:      v.heading ?? 0,
            report_count: v.report_count,
            crowding:     v.crowding ?? '',
            is_estimate:  false,
          }
        })
      }
    }
    src.setData({ type: 'FeatureCollection', features })
  }, [])

  // ── WebSocket connection ────────────────────────────────────────────────
  useEffect(() => {
    if (!ready) return

    const connect = () => {
      ws.current = new WebSocket(WS_URL)

      ws.current.onopen = () => {
        ALL_LINE_IDS.forEach(id =>
          ws.current?.send(JSON.stringify({ type: 'subscribe', payload: { line_id: id } }))
        )
      }

      ws.current.onmessage = (event) => {
        const msg = JSON.parse(event.data)
        if (msg.type === 'vehicle_update') {
          const payload = msg.payload as WSPayload
          vehicles.current[payload.lineId] = payload.vehicles ?? []
          updateVehicleLayer()
        }
      }

      ws.current.onclose = () => setTimeout(connect, 3000)
    }

    connect()
    return () => ws.current?.close()
  }, [ready, updateVehicleLayer])

  return (
    <div ref={containerRef} style={{ width: '100vw', height: '100vh' }} />
  )
}
APPEOF
echo "  ✓ frontend/src/App.tsx (clean map view)"

# ── 6. MISSING __init__ FILES ─────────────────────────────────────────────
for d in backend/app/routers backend/app/websocket backend/app/models backend/app/tasks backend/app/ml backend/app/data; do
  touch "$d/__init__.py"
done
echo "  ✓ __init__.py files"

echo "\n✅ Core system built!"
echo "\nNext steps:"
echo "  1. ./download_geojson.sh          # fetch Metrobús routes"
echo "  2. docker compose restart backend  # reload with simulation"
echo "  3. open http://localhost:5173      # watch 500 users move"
