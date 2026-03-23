# Training Analyst Worker
# =======================
# Container for running training analysis jobs as Cloud Run Jobs.

FROM --platform=linux/amd64 python:3.11-slim

# Prevent stdout buffering
ENV PYTHONUNBUFFERED=1

# Don't write .pyc files
ENV PYTHONDONTWRITEBYTECODE=1

# Set PYTHONPATH
ENV PYTHONPATH=/app

WORKDIR /app

# Install dependencies
COPY worker_requirements.txt .
RUN pip install --no-cache-dir -r worker_requirements.txt

# Copy application code
COPY shared/ shared/
COPY app/ app/
COPY workers/ workers/

# Healthcheck
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD python -c "from workers.analyst_worker import AnalystWorker; print('ok')" || exit 1

# Create non-root user
RUN adduser --disabled-password --no-create-home --gecos "" appuser
USER appuser

# Default: run worker
CMD ["python", "workers/analyst_worker.py"]
