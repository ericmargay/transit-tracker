from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    DATABASE_URL: str = "postgresql+asyncpg://transit:transit_dev@db:5432/transit_tracker"
    MAPBOX_TOKEN: str = ""
    ML_MODEL_PATH: str = "/app/models"

    class Config:
        env_file = ".env"

settings = Settings()
