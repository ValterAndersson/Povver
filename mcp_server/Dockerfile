FROM --platform=linux/amd64 node:20-slim

WORKDIR /app

COPY package*.json ./
RUN npm ci --production

COPY dist/ dist/

# Import shared modules and utils from Firebase Functions
COPY shared/ shared/
COPY utils/ utils/

CMD ["node", "dist/index.js"]
