FROM golang:1.23-alpine AS builder

WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=1 go build -o /hiclaw-controller ./cmd/controller/
RUN CGO_ENABLED=0 go build -o /hiclaw ./cmd/hiclaw/

FROM alpine:3.20
RUN apk add --no-cache bash jq curl
COPY --from=builder /hiclaw-controller /usr/local/bin/hiclaw-controller
COPY --from=builder /hiclaw /usr/local/bin/hiclaw
ENTRYPOINT ["hiclaw-controller"]
