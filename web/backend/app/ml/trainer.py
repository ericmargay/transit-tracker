import pandas as pd
import numpy as np
import lightgbm as lgb
from sklearn.ensemble import IsolationForest
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_absolute_error, classification_report
import joblib
from pathlib import Path
from datetime import datetime, UTC
import logging

from app.ml.features import build_arrival_features, build_crowding_features

logger = logging.getLogger(__name__)
MODEL_DIR = Path("/app/models")


class ArrivalTimeTrainer:
    """
    Trains LightGBM to predict minutes until a vehicle reaches a stop.
    Same architecture as the France Property Prices spatial model,
    but target is minutes instead of price.
    """

    def train(self, df: pd.DataFrame) -> dict:
        """
        df must have columns:
          line_id, current_speed, avg_speed_5min, report_count,
          hour, minute, day_of_week, is_weekend, is_rush_am, is_rush_pm,
          hour_sin, hour_cos, dow_sin, dow_cos,
          distance_to_stop_km, bearing_to_stop,
          actual_minutes  ← label
        """
        feature_cols = [c for c in df.columns if c != "actual_minutes"]
        X = df[feature_cols]
        y = df["actual_minutes"]

        X_train, X_val, y_train, y_val = train_test_split(X, y, test_size=0.15)

        model = lgb.LGBMRegressor(
            n_estimators=500,
            learning_rate=0.05,
            num_leaves=63,
            min_child_samples=20,
            subsample=0.8,
            colsample_bytree=0.8,
            reg_alpha=0.1,
            reg_lambda=0.1,
            random_state=42,
            n_jobs=-1,
        )
        model.fit(
            X_train, y_train,
            eval_set=[(X_val, y_val)],
            callbacks=[lgb.early_stopping(50), lgb.log_evaluation(100)],
        )

        preds = model.predict(X_val)
        mae = mean_absolute_error(y_val, preds)
        logger.info(f"Arrival model MAE: {mae:.2f} minutes")

        version = datetime.now(UTC).strftime("%Y%m%d_%H%M")
        path = MODEL_DIR / f"arrival_model_{version}.joblib"
        joblib.dump(model, path)
        # Always overwrite the "latest" pointer
        joblib.dump(model, MODEL_DIR / "arrival_model_latest.joblib")

        return {"mae_minutes": mae, "version": version, "n_samples": len(df)}


class CrowdingTrainer:

    CROWDING_MAP = {"empty": 0, "light": 1, "moderate": 2, "packed": 3}

    def train(self, df: pd.DataFrame) -> dict:
        df["label"] = df["crowding"].map(self.CROWDING_MAP)
        feature_cols = [c for c in df.columns if c not in ["crowding", "label"]]
        X, y = df[feature_cols], df["label"]

        X_train, X_val, y_train, y_val = train_test_split(X, y, test_size=0.15)

        model = lgb.LGBMClassifier(
            n_estimators=300,
            learning_rate=0.05,
            num_leaves=31,
            num_class=4,
            objective="multiclass",
            random_state=42,
        )
        model.fit(X_train, y_train,
                  eval_set=[(X_val, y_val)],
                  callbacks=[lgb.early_stopping(30)])

        report = classification_report(y_val, model.predict(X_val))
        logger.info(f"Crowding model:\n{report}")

        version = datetime.now(UTC).strftime("%Y%m%d_%H%M")
        joblib.dump(model, MODEL_DIR / f"crowding_model_{version}.joblib")
        joblib.dump(model, MODEL_DIR / "crowding_model_latest.joblib")

        return {"version": version, "n_samples": len(df)}


class AnomalyDetectorTrainer:
    """
    Isolation Forest trained on normal operating patterns.
    No labels needed — it learns what normal looks like,
    then flags deviations (delays, breakdowns, unusual gaps).
    """

    def train(self, df: pd.DataFrame) -> dict:
        feature_cols = ["hour", "day_of_week", "current_speed",
                        "distance_to_stop_km", "report_count"]
        X = df[feature_cols].dropna()

        model = IsolationForest(
            n_estimators=200,
            contamination=0.05,  # assume 5% of historical data was anomalous
            random_state=42,
            n_jobs=-1,
        )
        model.fit(X)

        version = datetime.now(UTC).strftime("%Y%m%d_%H%M")
        joblib.dump(model, MODEL_DIR / f"anomaly_model_{version}.joblib")
        joblib.dump(model, MODEL_DIR / "anomaly_model_latest.joblib")

        return {"version": version, "n_samples": len(X)}