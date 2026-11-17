FROM golang:1.26-alpine AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/slo-exporter .

FROM alpine:3.22
RUN addgroup -S -g 10001 sloexporter \
    && adduser -S -D -H -u 10001 -G sloexporter -s /sbin/nologin sloexporter
COPY --from=builder /out/slo-exporter /usr/local/bin/slo-exporter
USER 10001:10001
EXPOSE 9100
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:9100/metrics || exit 1
ENTRYPOINT ["/usr/local/bin/slo-exporter"]
