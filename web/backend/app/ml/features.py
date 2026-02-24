import pandas as pd
import numpy as np
from datetime import datetime


def extract_temporal_features(dt: datetime) -> dict:
    """
    Core temporal features — same philosophy as France project's
    time-of-year features, but now minute-level granularity matters.
    """
    return {
        "hour":           dt.hour,
        "minute":         dt.minute,
        "day_of_week":    dt.weekday(),       # 0=Monday, 6=Sunday
        "is_weekend":     int(dt.weekday() >= 5),
        "is_rush_am":     int(7 <= dt.hour <= 9),
        "is_rush_pm":     int(17 <= dt.hour <= 20),
        "is_offpeak":     int(10 <= dt.hour <= 16),
        "is_late_night":  int(dt.hour >= 22 or dt.hour <= 5),
        # Cyclical encoding — preserves 23:59 → 00:00 continuity
        "hour_sin":       np.sin(2 * np.pi * dt.hour / 24),
        "hour_cos":       np.cos(2 * np.pi * dt.hour / 24),
        "dow_sin":        np.sin(2 * np.pi * dt.weekday() / 7),
        "dow_cos":        np.cos(2 * np.pi * dt.weekday() / 7),
    }


def extract_spatial_features(lat: float, lon: float,
                              stop_lat: float, stop_lon: float) -> dict:
    """Distance and bearing from vehicle to next stop."""
    dlat = np.radians(stop_lat - lat)
    dlon = np.radians(stop_lon - lon)
    a = (np.sin(dlat/2)**2 +
         np.cos(np.radians(lat)) * np.cos(np.radians(stop_lat)) * np.sin(dlon/2)**2)
    distance_km = 6371 * 2 * np.arctan2(np.sqrt(a), np.sqrt(1-a))

    bearing = np.degrees(np.arctan2(
        np.sin(dlon) * np.cos(np.radians(stop_lat)),
        np.cos(np.radians(lat)) * np.sin(np.radians(stop_lat)) -
        np.sin(np.radians(lat)) * np.cos(np.radians(stop_lat)) * np.cos(dlon)
    ))

    return {
        "distance_to_stop_km": distance_km,
        "bearing_to_stop":     bearing,
    }


def build_arrival_features(
    line_id: str,
    current_lat: float, current_lon: float,
    current_speed_ms: float,
    stop_lat: float, stop_lon: float,
    dt: datetime,
    recent_avg_speed: float,
    report_count: int,
) -> pd.DataFrame:
    """
    Build the full feature vector for arrival time prediction.
    Returns a single-row DataFrame ready for LightGBM inference.
    """
    line_num = line_id.split("-")[-1]

    features = {
        "line_num":       hash(line_num) % 20,
        "current_speed":  current_speed_ms * 3.6,   # convert to km/h
        "avg_speed_5min": recent_avg_speed * 3.6,
        "report_count":   report_count,
        **extract_temporal_features(dt),
        **extract_spatial_features(current_lat, current_lon, stop_lat, stop_lon),
    }
    return pd.DataFrame([features])


def build_crowding_features(
    line_id: str,
    stop_id: str,
    dt: datetime,
    historical_crowding_score: float,  # 0–3 mean of past crowding at this stop+time
) -> pd.DataFrame:
    features = {
        "line_num":                 hash(line_id) % 20,
        "stop_num":                 hash(stop_id) % 200,
        "historical_crowding":      historical_crowding_score,
        **extract_temporal_features(dt),
    }
    return pd.DataFrame([features])