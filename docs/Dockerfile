# node:24.19.0-alpine verified linux/amd64 manifest digest.
FROM node:24.19.0-alpine@sha256:2a49bdf71e9fd965a58c1703fd9ddd205b34e5782b692a72dd1d248abb0beb43 AS dependencies

WORKDIR /workspace/docs

COPY docs/package.json docs/package-lock.json ./
RUN npm ci --ignore-scripts

FROM dependencies AS test

WORKDIR /workspace
COPY docs/ ./docs/
COPY CONTRIBUTING.md SECURITY.md /workspace/
COPY .dockerignore /workspace/.dockerignore
COPY .github/workflows/ci.yml /workspace/.github/workflows/ci.yml
COPY .github/PULL_REQUEST_TEMPLATE.md /workspace/.github/PULL_REQUEST_TEMPLATE.md
COPY .github/ISSUE_TEMPLATE/bug_report.md /workspace/.github/ISSUE_TEMPLATE/bug_report.md
COPY android-client/Dockerfile.ci /workspace/android-client/Dockerfile.ci
COPY android-client/android/app/build.gradle /workspace/android-client/android/app/build.gradle
COPY android-client/android/app/src/main/AndroidManifest.xml /workspace/android-client/android/app/src/main/AndroidManifest.xml
COPY wallet-plugin-go/Dockerfile /workspace/wallet-plugin-go/Dockerfile
COPY wallet-plugin-go/internal/pairing/testdata/pairing-signed-qr.vector.json /workspace/wallet-plugin-go/internal/pairing/testdata/pairing-signed-qr.vector.json
COPY wallet-plugin-go/internal/pairing/testdata/pairing-key-schedule.vector.json /workspace/wallet-plugin-go/internal/pairing/testdata/pairing-key-schedule.vector.json
COPY wallet-plugin-go/internal/pairing/testdata/pairing-protocol.vector.json /workspace/wallet-plugin-go/internal/pairing/testdata/pairing-protocol.vector.json
COPY wallet-plugin-go/internal/analytics/testdata/sales-analytics.vector.json /workspace/wallet-plugin-go/internal/analytics/testdata/sales-analytics.vector.json
WORKDIR /workspace/docs
RUN npm test
