FROM mcr.microsoft.com/playwright:v1.57.0-noble@sha256:8fb7af3bb488c51364d6554876a8eddf377736608327dbdf4177b4901faf7bc9

WORKDIR /browser

COPY server/package.json server/package-lock.json ./
RUN npm ci --ignore-scripts --no-audit --no-fund

COPY server/playwright.config.js ./
COPY server/tests/Browser ./tests/Browser

CMD ["npx", "playwright", "test"]
