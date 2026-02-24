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
