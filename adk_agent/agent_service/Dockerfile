# Pin to SHA digest for supply-chain safety. Update digest when upgrading base image.
FROM --platform=linux/amd64 python:3.11-slim@sha256:16cb75beff0e104520a4bc4e98b08987b6978b82e37b81b87d786504e17579e7

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONPATH=/app

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ app/
COPY shared/ shared/

# Create non-root user
RUN adduser --disabled-password --no-create-home --gecos "" appuser
USER appuser

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
