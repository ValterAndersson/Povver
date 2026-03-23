FROM --platform=linux/amd64 node:20-slim

WORKDIR /app

COPY package*.json ./
RUN npm ci

# Copy source and compile TypeScript
COPY tsconfig.json ./
COPY src/ src/
RUN npx tsc
RUN npm prune --production

# Import shared modules and utils from Firebase Functions
# These are CommonJS but our package.json says "type": "module",
# so we add a CJS package.json to each directory
COPY shared/ shared/
COPY utils/ utils/
COPY shared-package.json shared/package.json
COPY shared-package.json utils/package.json

# Create non-root user
RUN adduser --disabled-password --no-create-home --gecos "" appuser
USER appuser

CMD ["node", "dist/index.js"]
