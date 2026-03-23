# Pin to SHA digest for supply-chain safety. Update digest when upgrading base image.
FROM --platform=linux/amd64 python:3.11-slim@sha256:16cb75beff0e104520a4bc4e98b08987b6978b82e37b81b87d786504e17579e7

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application
COPY app.py .
COPY templates/ templates/
COPY static/ static/

# Set environment variables
ENV PORT=8080
ENV GOOGLE_CLOUD_PROJECT=myon-53d85
ENV CLOUD_RUN_REGION=europe-west1

# Run with gunicorn for production
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 0 app:app
