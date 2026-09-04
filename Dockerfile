# syntax=docker/dockerfile:1

FROM python:3.12-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/main.py .

# Baked in at build time so /version reflects exactly what was built,
# without needing a Terraform/task-definition change per release.
ARG APP_VERSION=0.0.0
ARG GIT_COMMIT=unknown
ARG BUILD_NUMBER=unknown
ENV APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT} \
    BUILD_NUMBER=${BUILD_NUMBER}

RUN addgroup --system app && adduser --system --ingroup app app
USER app

# Documentation only — Fargate ignores this and reads the ALB/task
# definition's container port instead.
EXPOSE 8000

# Container-level check for local `docker run`; the ECS task definition
# defines its own ECS-native healthCheck for the same /health endpoint.
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2)" || exit 1

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
