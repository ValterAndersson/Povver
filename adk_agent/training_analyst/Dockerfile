# Training Analyst Worker
# =======================
# Container for running training analysis jobs as Cloud Run Jobs.

# Pin to SHA digest for supply-chain safety. Update digest when upgrading base image.
FROM --platform=linux/amd64 python:3.11-slim@sha256:16cb75beff0e104520a4bc4e98b08987b6978b82e37b81b87d786504e17579e7

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
