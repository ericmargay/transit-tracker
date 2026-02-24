#!/usr/bin/env bash
# Smooth wagon movement: client-side interpolation + proper speed physics

# ── 1. BACKEND: physics-based speed + station slowdowns ─────────────────
cat > backend/app/tasks/simulation.py << 'EOF'
"""
Physics-based wagon simulation.
- Proper acceleration/deceleration curves
- Station stops with realistic dwell
- Max speed 25 m/s (~90 km/h) for Metro, 14 m/s (~50 km/h) for Metrobús
- Sends position + speed + heading every tick
"""
import asyncio, json, math, random, logging
from pathlib import Path

logger     = logging.getLogger(__name__)
GEOJSON_DIR = Path("/app/geojson")

TICK_S          = 2        # send updates every 2s for smoother interpolation
NOISE_M         = 8        # tighter GPS noise for smoother paths
METRO_MAX_MS    = 25.0     # 90 km/h
BUS_MAX_MS      = 14.0     # 50 km/h
METRO_ACCEL     = 1.2      # m/s²
BUS_ACCEL       = 0.7
DECEL_DISTANCE  = 180      # metres before stop: start braking
STATION_SPACING = 900      # average metres between stations
DWELL_MIN       = 18       # seconds at station
DWELL_MAX       = 35

MAX_WAGONS = {
    "metro-1": 7, "metro-2": 7, "metro-3": 7, "metro-4": 5,
    "metro-5": 6, "metro-6": 5, "metro-7": 6, "metro-8": 6,
    "metro-9": 6, "metro-a": 5, "metro-b": 7, "metro-12": 6,
    "metrobus-1": 8, "metrobus-2": 7, "metrobus-3": 7,
    "metrobus-4": 6, "metrobus-5": 5, "metrobus-6": 6, "metrobus-7": 6,
}

BUSY_ZONES = [
    (19.4252, -99.1344, 700),
    (19.4319, -99.1401, 500),
    (19.4270, -99.1674, 400),
    (19.4711, -99.1194, 400),
    (19.3580, -99.0719, 400),
    (19.3987, -99.0586, 350),
    (19.3296, -99.1876, 350),
    (19.4847, -99.1952, 350),
]


def haversine_m(lat1, lon1, lat2, lon2):
    R = 6_371_000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2-lat1); dl = math.radians(lon2-lon1)
    a  = math.sin(dp/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(dl/2)**2
    return R * 2 * math.atan2(math.sqrt(a), math.sqrt(1-a))


def bearing(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dl = math.radians(lon2-lon1)
    x  = math.sin(dl)*math.cos(p2)
    y  = math.cos(p1)*math.sin(p2) - math.sin(p1)*math.cos(p2)*math.cos(dl)
    return (math.degrees(math.atan2(x, y)) + 360) % 360


def add_noise(lat, lon, r_m=NOISE_M):
    r = r_m / 111_320
    a = random.uniform(0, 2*math.pi)
    return lat + r*math.sin(a), lon + r*math.cos(a)


def route_length(route):
    return sum(haversine_m(*route[i], *route[i+1]) for i in range(len(route)-1))


def build_route(features):
    segs = [f["geometry"]["coordinates"]
            for f in features if f.get("geometry",{}).get("type")=="LineString"]
    if not segs: return []
    result = list(segs[0])
    for seg in segs[1:]:
        if not seg: continue
        d_ff = haversine_m(result[-1][1],result[-1][0],seg[0][1], seg[0][0])
        d_fr = haversine_m(result[-1][1],result[-1][0],seg[-1][1],seg[-1][0])
        if d_fr < d_ff: seg = list(reversed(seg))
        if haversine_m(result[-1][1],result[-1][0],seg[0][1],seg[0][0]) < 3000:
            result.extend(seg[1:])
        else:
            result.extend(seg)
    return [(c[1], c[0]) for c in result]


def sample_at(route, dist_m):
    """Return (lat, lon, heading) at dist_m along route."""
    walked = 0.0
    for i in range(len(route)-1):
        seg = haversine_m(*route[i], *route[i+1])
        if walked + seg >= dist_m:
            frac = (dist_m - walked) / max(seg, 0.001)
            lat  = route[i][0] + frac*(route[i+1][0]-route[i][0])
            lon  = route[i][1] + frac*(route[i+1][1]-route[i][1])
            # Smooth heading: average bearing of current + next segment
            hdg  = bearing(*route[i], *route[i+1])
            if i+2 < len(route):
                hdg2   = bearing(*route[i+1], *route[i+2])
                # Interpolate headings (handle wrap-around)
                diff   = ((hdg2 - hdg + 180) % 360) - 180
                hdg    = hdg + frac * diff
            return lat, lon, hdg % 360
        walked += seg
    return route[-1][0], route[-1][1], 0.0


def in_busy_zone(lat, lon):
    for zlat, zlon, zr in BUSY_ZONES:
        d = haversine_m(lat, lon, zlat, zlon)
        if d < zr:
            return 1.0 - (d / zr)
    return 0.0


class SimWagon:
    def __init__(self, line_id, route, max_ms, accel, offset_m, direction):
        self.line_id    = line_id
        self.route      = route
        self.max_ms     = max_ms * random.uniform(0.88, 1.0)
        self.accel      = accel
        self.length     = route_length(route)
        self.position   = offset_m % self.length
        self.direction  = direction
        self.speed_ms   = 0.0
        self.dwell_left = random.uniform(0, DWELL_MAX)   # stagger starts
        self.passengers = random.randint(2, 8)
        self._next_board_dist = random.uniform(300, STATION_SPACING)

    @property
    def dist_to_next_stop(self):
        """Estimate distance to next virtual stop."""
        return self._next_board_dist

    def step(self, dt_s):
        # ── Dwell at stop ─────────────────────────────────────────────
        if self.dwell_left > 0:
            self.dwell_left = max(0, self.dwell_left - dt_s)
            self.speed_ms   = 0.0
            return

        # ── Busy zone congestion ──────────────────────────────────────
        lat, lon, _ = sample_at(self.route, self.position)
        busy        = in_busy_zone(lat, lon)

        # Effective max speed reduced by congestion and random variance
        target_max = self.max_ms * (1.0 - busy * 0.75)
        # Random incident (2% chance)
        if random.random() < 0.02:
            target_max *= random.uniform(0.1, 0.35)

        # ── Speed profile: brake before stop, accelerate away ─────────
        d_to_stop = self._next_board_dist
        if d_to_stop < DECEL_DISTANCE:
            # Deceleration phase: target speed proportional to distance
            frac         = d_to_stop / DECEL_DISTANCE
            target_speed = target_max * max(0.02, frac)
        else:
            target_speed = target_max

        # Smooth acceleration/deceleration
        if self.speed_ms < target_speed:
            self.speed_ms = min(target_speed, self.speed_ms + self.accel * dt_s)
        else:
            decel = self.accel * 2.5   # brake harder than accelerate
            self.speed_ms = max(target_speed, self.speed_ms - decel * dt_s)

        # ── Move ──────────────────────────────────────────────────────
        delta = self.speed_ms * dt_s
        self._next_board_dist -= delta
        self.position         += self.direction * delta

        # ── Reached stop ─────────────────────────────────────────────
        if self._next_board_dist <= 0:
            self.speed_ms = 0.0
            self.dwell_left = random.uniform(DWELL_MIN, DWELL_MAX)
            if busy > 0.4:
                self.dwell_left *= (1 + busy)   # longer dwell at busy stations
            # Passenger churn
            alight = random.randint(0, min(self.passengers, 5))
            board  = random.randint(0, min(10 - self.passengers + alight, int(3 + busy*7)))
            self.passengers = max(0, min(10, self.passengers - alight + board))
            self._next_board_dist = random.uniform(
                STATION_SPACING * 0.6, STATION_SPACING * 1.4
            )

        # ── Terminal bounce ───────────────────────────────────────────
        if self.position >= self.length:
            self.position   = self.length - (self.position - self.length)
            self.direction  = -1
            self.speed_ms   = 0.0
            self.dwell_left = random.uniform(DWELL_MIN, DWELL_MAX)
        elif self.position <= 0:
            self.position   = abs(self.position)
            self.direction  = 1
            self.speed_ms   = 0.0
            self.dwell_left = random.uniform(DWELL_MIN, DWELL_MAX)

    def get_report(self):
        if self.passengers == 0:
            return None
        route = self.route if self.direction == 1 else list(reversed(self.route))
        pos   = self.position if self.direction == 1 else self.length - self.position
        lat, lon, hdg = sample_at(route, pos)
        nlat, nlon    = add_noise(lat, lon)
        return {
            "line_id":    self.line_id,
            "latitude":   nlat,
            "longitude":  nlon,
            "heading":    (hdg + random.gauss(0, 2)) % 360,
            "speed_ms":   max(0.0, self.speed_ms),
            "crowding":   "packed" if self.passengers > 7 else
                          "moderate" if self.passengers > 4 else
                          "light" if self.passengers > 1 else "empty",
            "session_id": f"sim-{self.line_id}-{id(self)}-0",
        }


def load_wagons():
    wagons = []
    for gf in GEOJSON_DIR.glob("*_lines.geojson"):
        is_metro = "metro_lines" in gf.name
        max_ms   = METRO_MAX_MS if is_metro else BUS_MAX_MS
        accel    = METRO_ACCEL  if is_metro else BUS_ACCEL
        try:
            features = json.loads(gf.read_text()).get("features", [])
        except Exception as e:
            logger.warning(f"{gf.name}: {e}"); continue

        by_line: dict[str, list] = {}
        for f in features:
            lid = f.get("properties",{}).get("line_id","unknown")
            by_line.setdefault(lid, []).append(f)

        for line_id, feats in by_line.items():
            route = build_route(feats)
            if len(route) < 2: continue
            length   = route_length(route)
            cap      = MAX_WAGONS.get(line_id, 6)
            n_wagons = min(cap, max(3, int(length / 3000)))
            spacing  = length / n_wagons
            logger.info(f"  {line_id}: {length/1000:.1f}km → {n_wagons} wagons")
            for i in range(n_wagons):
                wagons.append(SimWagon(
                    line_id, route, max_ms, accel,
                    offset_m  = i * spacing + random.uniform(-100, 100),
                    direction = 1 if i % 2 == 0 else -1,
                ))

    logger.info(f"✅ {len(wagons)} wagons")
    return wagons


async def run_simulation(db_factory):
    wagons = load_wagons()
    if not wagons:
        logger.warning("No routes"); return

    from sqlalchemy import text as sa_text
    from app.routers.vehicles import aggregate_and_broadcast

    while True:
        t0 = asyncio.get_event_loop().time()

        for w in wagons:
            w.step(TICK_S)

        reports = [r for w in wagons for r in [w.get_report()] if r]
        if reports:
            async with db_factory() as db:
                await db.execute(sa_text("""
                    INSERT INTO vehicle_reports
                        (id,line_id,session_id,latitude,longitude,
                         heading,speed_ms,crowding,reported_at)
                    VALUES
                        (gen_random_uuid(),:line_id,:session_id,:latitude,:longitude,
                         :heading,:speed_ms,:crowding,NOW())
                """), reports)
                await db.commit()
                for lid in {r["line_id"] for r in reports}:
                    await aggregate_and_broadcast(lid, db)

        elapsed = asyncio.get_event_loop().time() - t0
        await asyncio.sleep(max(0.05, TICK_S - elapsed))
EOF

# ── 2. FRONTEND: smooth client-side interpolation ───────────────────────
cat > frontend/src/App.tsx << 'EOF'
/**
 * CDMX Transit Tracker
 * Smooth wagon movement via client-side linear interpolation.
 * Every 2s we receive a new position from WS; rAF loop moves wagons
 * smoothly between old and new positions over exactly that 2s window.
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

const STATUS_COLOR: Record<string, string> = {
  normal:  '#22c55e',
  slow:    '#f59e0b',
  stopped: '#ef4444',
}

// Interpolation window in ms — should match backend TICK_S
const INTERP_MS = 2000

interface VehicleState {
  fromLng: number; fromLat: number
  toLng:   number; toLat:   number
  fromHdg: number; toHdg:   number
  speed_ms: number; speed_status: string
  passengers: number; line_id: string
  startedAt: number   // timestamp when transition began
  id: string          // stable key
}

// Lerp scalar
const lerp = (a: number, b: number, t: number) => a + (b - a) * t

// Lerp angle (shortest path)
function lerpAngle(a: number, b: number, t: number) {
  let diff = ((b - a + 180) % 360) - 180
  return (a + diff * t + 360) % 360
}

function makeSprite(type: 'metro' | 'metrobus', color: string, size = 64) {
  const c   = document.createElement('canvas')
  c.width   = size; c.height = size
  const ctx = c.getContext('2d')!
  const isMetro = type === 'metro'
  const w   = isMetro ? size * 0.88 : size * 0.54
  const h   = isMetro ? size * 0.32 : size * 0.40
  const x   = (size - w) / 2, y = (size - h) / 2
  const r   = h / 2

  ctx.shadowColor   = 'rgba(0,0,0,0.55)'
  ctx.shadowBlur    = 5
  ctx.shadowOffsetY = 2

  ctx.beginPath()
  ctx.moveTo(x+r, y)
  ctx.lineTo(x+w-r, y)
  ctx.quadraticCurveTo(x+w, y,     x+w, y+r)
  ctx.lineTo(x+w, y+h-r)
  ctx.quadraticCurveTo(x+w, y+h,   x+w-r, y+h)
  ctx.lineTo(x+r, y+h)
  ctx.quadraticCurveTo(x, y+h,     x, y+h-r)
  ctx.lineTo(x, y+r)
  ctx.quadraticCurveTo(x, y,       x+r, y)
  ctx.closePath()
  ctx.fillStyle = color
  ctx.fill()

  ctx.shadowColor = 'transparent'
  ctx.fillStyle   = 'rgba(255,255,255,0.20)'
  ctx.fillRect(x + w*0.14, y + h*0.18, w*0.72, h*0.28)
  ctx.strokeStyle = 'rgba(255,255,255,0.85)'
  ctx.lineWidth   = 1.8
  ctx.stroke()

  return ctx.getImageData(0, 0, size, size)
}

export default function App() {
  const containerRef = useRef<HTMLDivElement>(null)
  const map          = useRef<mapboxgl.Map | null>(null)
  const ws           = useRef<WebSocket | null>(null)
  const rafId        = useRef<number>(0)
  const [ready, setReady] = useState(false)

  // Stable vehicle state map: stableId → VehicleState
  const stateRef = useRef<Map<string, VehicleState>>(new Map())

  // ── Map init ────────────────────────────────────────────────────────
  useEffect(() => {
    if (map.current || !containerRef.current) return
    const m = new mapboxgl.Map({
      container: containerRef.current,
      style: 'mapbox://styles/mapbox/dark-v11',
      center: [-99.1332, 19.4326],
      zoom: 11.2,
      attributionControl: false,
    })
    m.addControl(new mapboxgl.AttributionControl({ compact: true }), 'bottom-right')
    m.on('load', () => { map.current = m; initLayers(m); setReady(true) })
    return () => { m.remove(); map.current = null }
  }, [])

  // ── Layers ──────────────────────────────────────────────────────────
  const initLayers = useCallback(async (m: mapboxgl.Map) => {
    for (const sys of ['metro','metrobus'] as const)
      for (const st of ['normal','slow','stopped'] as const) {
        const d = makeSprite(sys, STATUS_COLOR[st])
        m.addImage(`wagon-${sys}-${st}`, { width:d.width, height:d.height, data:d.data })
      }

    const load = async (url: string) => {
      const r = await fetch(url); if (!r.ok) throw new Error(url); return r.json()
    }

    try {
      const [mLines, mStops, bLines, bStops] = await Promise.all([
        load('/geojson/metro_lines.geojson'),
        load('/geojson/metro_stops.geojson'),
        load('/geojson/metrobus_lines.geojson').catch(()=>({type:'FeatureCollection',features:[]})),
        load('/geojson/metrobus_stops.geojson').catch(()=>({type:'FeatureCollection',features:[]})),
      ])

      for (const [id, data, w] of [
        ['metro-lines',    mLines, 4],
        ['metrobus-lines', bLines, 3],
      ] as [string, any, number][]) {
        m.addSource(id, { type:'geojson', data })
        m.addLayer({ id:`${id}-casing`, type:'line', source:id,
          layout: { 'line-cap':'round','line-join':'round' },
          paint:  { 'line-color':'#000','line-width':w+3,'line-opacity':0.5 } })
        m.addLayer({ id:`${id}-fill`, type:'line', source:id,
          layout: { 'line-cap':'round','line-join':'round' },
          paint:  { 'line-color':['get','line_color'],'line-width':w,'line-opacity':0.95 } })
      }

      for (const [id, data] of [
        ['metro-stops',    mStops],
        ['metrobus-stops', bStops],
      ] as [string, any][]) {
        m.addSource(id, { type:'geojson', data })
        m.addLayer({ id:`${id}-dot`, type:'circle', source:id,
          paint: {
            'circle-color': '#fff',
            'circle-radius': ['interpolate',['linear'],['zoom'],10,2,15,6],
            'circle-stroke-color': ['get','line_color'],
            'circle-stroke-width': ['interpolate',['linear'],['zoom'],10,1,15,3],
          }
        })
        m.addLayer({ id:`${id}-lbl`, type:'symbol', source:id, minzoom:13,
          layout: { 'text-field':['get','stop_name'],'text-size':10,'text-offset':[0,1.3],'text-anchor':'top','text-optional':true },
          paint:  { 'text-color':'#fff','text-halo-color':'#000','text-halo-width':1.2 }
        })
        m.on('mouseenter',`${id}-dot`,()=>m.getCanvas().style.cursor='pointer')
        m.on('mouseleave',`${id}-dot`,()=>m.getCanvas().style.cursor='')
        m.on('click',`${id}-dot`,(e)=>{
          const p=e.features?.[0]?.properties as any; if(!p) return
          const line=lineById(p.line_id)
          new mapboxgl.Popup({closeButton:false,offset:8}).setLngLat(e.lngLat)
            .setHTML(`<div style="font:13px/1.4 system-ui;padding:4px 8px">
              <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??''}</span>
              <div style="font-weight:600;margin-top:5px">${p.stop_name}</div>
            </div>`).addTo(m)
        })
      }

      m.addSource('vehicles', { type:'geojson', data:{ type:'FeatureCollection', features:[] } })
      m.addLayer({ id:'vehicle-icon', type:'symbol', source:'vehicles',
        layout: {
          'icon-image':              ['get','icon'],
          'icon-size':               ['interpolate',['linear'],['zoom'],9,0.45,12,0.75,15,1.3],
          'icon-rotate':             ['get','heading'],
          'icon-rotation-alignment': 'map',
          'icon-allow-overlap':      true,
          'icon-ignore-placement':   true,
          'text-field':              ['get','label'],
          'text-size':               10,
          'text-font':               ['DIN Offc Pro Bold','Arial Unicode MS Bold'],
          'text-allow-overlap':      true,
          'text-ignore-placement':   true,
          'text-anchor':             'center',
          'text-rotation-alignment': 'viewport',
        },
        paint: { 'text-color':'#fff','text-halo-color':'rgba(0,0,0,0.5)','text-halo-width':1 }
      })

      m.on('mouseenter','vehicle-icon',()=>m.getCanvas().style.cursor='pointer')
      m.on('mouseleave','vehicle-icon',()=>m.getCanvas().style.cursor='')
      m.on('click','vehicle-icon',(e)=>{
        const p=e.features?.[0]?.properties as any; if(!p) return
        const line=lineById(p.line_id)
        const kmh=(p.speed_ms*3.6).toFixed(0)
        const lbl: Record<string,string>={normal:'Normal ✅',slow:'Lento ⚠️',stopped:'Detenido 🔴'}
        new mapboxgl.Popup({closeButton:false,offset:14})
          .setLngLat((e.features![0].geometry as any).coordinates)
          .setHTML(`<div style="font:13px/1.6 system-ui;padding:6px 10px;min-width:160px">
            <span style="background:${line?.colorHex??'#888'};color:#fff;padding:1px 8px;border-radius:10px;font-size:11px;font-weight:700">${line?.shortName??p.line_id}</span>
            <div style="margin-top:6px;font-weight:700">${lbl[p.speed_status]??'—'}</div>
            <div style="color:#666;font-size:11px">${kmh} km/h · ${p.passengers} pasajero${p.passengers!==1?'s':''}</div>
          </div>`).addTo(m)
      })

    } catch(e) { console.warn('Layer error:', e) }
  }, [])

  // ── rAF render loop: interpolate all wagons every frame ─────────────
  const renderLoop = useCallback(() => {
    const m = map.current
    if (!m) { rafId.current = requestAnimationFrame(renderLoop); return }
    const src = m.getSource('vehicles') as mapboxgl.GeoJSONSource
    if (!src) { rafId.current = requestAnimationFrame(renderLoop); return }

    const now      = performance.now()
    const features: GeoJSON.Feature[] = []

    stateRef.current.forEach((v) => {
      const t       = Math.min(1, (now - v.startedAt) / INTERP_MS)
      // Ease in-out cubic for extra smoothness
      const ease    = t < 0.5 ? 4*t*t*t : 1 - Math.pow(-2*t+2,3)/2
      const lng     = lerp(v.fromLng, v.toLng, ease)
      const lat     = lerp(v.fromLat, v.toLat, ease)
      const heading = lerpAngle(v.fromHdg, v.toHdg, ease)

      const line    = lineById(v.line_id)
      const isMetro = v.line_id.startsWith('metro-') && !v.line_id.startsWith('metrobus-')

      features.push({
        type: 'Feature',
        geometry: { type:'Point', coordinates:[lng, lat] },
        properties: {
          line_id:      v.line_id,
          icon:         `wagon-${isMetro?'metro':'metrobus'}-${v.speed_status}`,
          heading,
          speed_ms:     v.speed_ms,
          speed_status: v.speed_status,
          passengers:   v.passengers,
          label:        v.passengers > 0 ? String(v.passengers) : '',
        }
      })
    })

    src.setData({ type:'FeatureCollection', features })
    rafId.current = requestAnimationFrame(renderLoop)
  }, [])

  // ── WebSocket: update target positions ──────────────────────────────
  useEffect(() => {
    if (!ready) return

    // Start render loop
    rafId.current = requestAnimationFrame(renderLoop)

    const connect = () => {
      const socket = new WebSocket(WS_URL)
      ws.current   = socket

      socket.onopen = () =>
        ALL_LINE_IDS.forEach(id =>
          socket.send(JSON.stringify({ type:'subscribe', payload:{ line_id:id } }))
        )

      socket.onmessage = (e) => {
        const msg = JSON.parse(e.data)
        if (msg.type !== 'vehicle_update') return

        const { lineId, vehicles } = msg.payload
        const now = performance.now()

        // Match incoming clusters to existing state by proximity
        const incoming: any[] = vehicles ?? []
        const existing = [...stateRef.current.entries()]
          .filter(([k]) => k.startsWith(lineId + '-'))

        incoming.forEach((v, i) => {
          const stableId = `${lineId}-${i}`
          const prev     = stateRef.current.get(stableId)

          stateRef.current.set(stableId, {
            fromLng: prev?.toLng ?? v.longitude,
            fromLat: prev?.toLat ?? v.latitude,
            toLng:   v.longitude,
            toLat:   v.latitude,
            fromHdg: prev?.toHdg ?? (v.heading ?? 0),
            toHdg:   v.heading ?? 0,
            speed_ms:     v.speed_ms ?? 0,
            speed_status: v.speed_status ?? 'normal',
            passengers:   v.passengers ?? 0,
            line_id:      lineId,
            startedAt:    now,
            id:           stableId,
          })
        })

        // Remove stale vehicles (line now has fewer clusters)
        existing.forEach(([k]) => {
          const idx = parseInt(k.split('-').pop()!)
          if (idx >= incoming.length) stateRef.current.delete(k)
        })
      }

      socket.onclose = () => setTimeout(connect, 3000)
    }

    connect()
    return () => {
      cancelAnimationFrame(rafId.current)
      ws.current?.close()
    }
  }, [ready, renderLoop])

  return <div ref={containerRef} style={{ width:'100vw', height:'100vh' }} />
}
EOF

echo "✅ Done. Run: docker compose restart backend"
