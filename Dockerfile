# TikTok Signature Server
FROM node:20-slim

# Install system libraries required by Chrome (not Chrome itself)
RUN apt-get update && apt-get install -y \
    fonts-liberation \
    libasound2 \
    libatk-bridge2.0-0 \
    libatk1.0-0 \
    libcups2 \
    libdbus-1-3 \
    libdrm2 \
    libgbm1 \
    libgtk-3-0 \
    libnspr4 \
    libnss3 \
    libx11-xcb1 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    xdg-utils \
    curl \
    --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Cache Puppeteer's Chrome download inside /app so UID 100 can access it
ENV PUPPETEER_CACHE_DIR=/app/.cache

# Copy package files
COPY package*.json ./

# Install dependencies — Puppeteer downloads its own Chrome here
RUN npm ci --only=production

# Copy application files
COPY server.mjs ./
COPY xgnarly.mjs ./
COPY benchmark.mjs ./
COPY javascript/ ./javascript/

RUN chown -R 100:100 /app
USER 100

ENV PORT=8080

EXPOSE 8080

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:8080/health || exit 1

CMD ["node", "server.mjs"]
