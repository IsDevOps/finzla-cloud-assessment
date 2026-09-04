import logging
import os
import sys
from contextlib import asynccontextmanager
from datetime import datetime, timezone

from fastapi import FastAPI

logging.basicConfig(
    stream=sys.stdout,
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("finzla-service")

APP_ENV = os.environ.get("APP_ENV", "development")
APP_VERSION = os.environ.get("APP_VERSION", "0.0.0")
GIT_COMMIT = os.environ.get("GIT_COMMIT", "unknown")
BUILD_NUMBER = os.environ.get("BUILD_NUMBER", "unknown")


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info(
        "service starting env=%s version=%s commit=%s build=%s",
        APP_ENV,
        APP_VERSION,
        GIT_COMMIT,
        BUILD_NUMBER,
    )
    yield


app = FastAPI(title="Finzla Assessment Service", lifespan=lifespan)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "time": datetime.now(timezone.utc).isoformat()}


@app.get("/version")
async def version() -> dict:
    return {
        "version": APP_VERSION,
        "git_commit": GIT_COMMIT,
        "build_number": BUILD_NUMBER,
        "env": APP_ENV,
    }


@app.get("/")
async def root() -> dict:
    logger.info("root endpoint hit")
    return {"service": "finzla-assessment", "env": APP_ENV}
