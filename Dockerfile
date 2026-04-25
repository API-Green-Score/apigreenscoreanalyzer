# ─────────────────────────────────────────────────────────────
#  Green Analyzer — Packaged Docker Image
#  All source code is embedded inside the image.
# ─────────────────────────────────────────────────────────────
FROM python:3.11-slim

LABEL maintainer="Green Analyzer Team"
LABEL description="API eco-design scoring toolkit — Green Score out of 100"

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    bash \
    jq \
    nodejs \
    npm \
    && npm install -g @stoplight/spectral-cli@6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY scripts/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt

# Copy all source code into the image (hidden from user)
WORKDIR /opt/greenanalyzer
COPY scripts/          ./scripts/
COPY dashboard/        ./dashboard/
COPY .spectral.yml     ./.spectral.yml
COPY green-score-threshold.json ./green-score-threshold.json

# Make scripts executable
RUN chmod +x scripts/*.sh scripts/*.py

# Default entrypoint = the Python engine
ENTRYPOINT ["python3", "/opt/greenanalyzer/scripts/green-api-auto-discover.py"]
CMD ["--help"]

