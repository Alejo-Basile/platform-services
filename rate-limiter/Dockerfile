FROM golang:1.24-alpine AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
COPY internal/ ./internal/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/ratelimitd ./cmd/ratelimitd

FROM alpine:3.22
RUN addgroup -S -g 10001 ratelimitd \
    && adduser -S -D -H -u 10001 -G ratelimitd -s /sbin/nologin ratelimitd
COPY --from=builder /out/ratelimitd /usr/local/bin/ratelimitd
USER 10001:10001
EXPOSE 8090
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8090/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/ratelimitd"]
