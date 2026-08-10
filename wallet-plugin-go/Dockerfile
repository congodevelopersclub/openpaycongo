FROM golang:1.26.5-bookworm AS base

WORKDIR /src

COPY go.mod go.sum ./
RUN go mod download

COPY . .

FROM base AS test
RUN go test ./... && go vet ./... && go test -race ./...

FROM base AS build
RUN CGO_ENABLED=1 go build -trimpath -ldflags='-s -w' -o /out/walletd ./cmd/server

FROM debian:bookworm-slim AS runtime

RUN useradd --system --uid 10001 --create-home --home-dir /data wallet

WORKDIR /data
VOLUME ["/data"]
EXPOSE 8080

COPY --from=build --chown=wallet:wallet /out/walletd /usr/local/bin/walletd

USER wallet
ENTRYPOINT ["/usr/local/bin/walletd"]
