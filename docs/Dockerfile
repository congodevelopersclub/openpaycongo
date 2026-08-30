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
COPY .gitleaks.toml /workspace/.gitleaks.toml
COPY .github/workflows/ci.yml /workspace/.github/workflows/ci.yml
COPY .github/workflows/security.yml /workspace/.github/workflows/security.yml
COPY .github/PULL_REQUEST_TEMPLATE.md /workspace/.github/PULL_REQUEST_TEMPLATE.md
COPY .github/ISSUE_TEMPLATE/bug_report.md /workspace/.github/ISSUE_TEMPLATE/bug_report.md
COPY README.md /workspace/README.md
COPY scripts/upgrade-quiescent.sh /workspace/scripts/upgrade-quiescent.sh
COPY server/Dockerfile /workspace/server/Dockerfile
COPY server/composer.json /workspace/server/composer.json
COPY server/phpstan.neon /workspace/server/phpstan.neon
COPY server/tests/Feature/AuthorizationBoundaryTest.php /workspace/server/tests/Feature/AuthorizationBoundaryTest.php
COPY android-client/Dockerfile.ci /workspace/android-client/Dockerfile.ci
COPY android-client/android/app/build.gradle /workspace/android-client/android/app/build.gradle
COPY android-client/android/app/src/main/AndroidManifest.xml /workspace/android-client/android/app/src/main/AndroidManifest.xml
COPY scripts/security/ /workspace/scripts/security/
WORKDIR /workspace/docs
RUN npm test
