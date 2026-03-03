# Build stage
FROM golang:alpine AS builder

WORKDIR /app

# Install git and certificates
RUN apk add --no-cache git ca-certificates tzdata

# Copy go mod and sum files
COPY go.mod go.sum ./

# Download all dependencies. Dependencies will be cached if the go.mod and go.sum files are not changed
RUN go mod download

# Copy the source code
COPY . .

# Build the application
# CGO_ENABLED=0 ensures a static binary
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -installsuffix cgo -ldflags="-w -s" -o api ./cmd/api

# Final stage
FROM scratch

# Import certs and timezone data from builder
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

WORKDIR /app

# Copy the static binary and assets
COPY --from=builder /app/api .
COPY static ./static

# Expose port
EXPOSE 8000

# Run the binary
ENTRYPOINT ["/app/api"]
