# HiClaw Makefile
# Provides common development, build, and deployment targets

.PHONY: all build test lint fmt vet clean docker-build docker-push helm-lint help

# Project metadata
PROJECT_NAME := hiclaw
MODULE := github.com/agentscope-ai/hiclaw
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo "dev")
COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo "unknown")
BUILD_DATE := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

# Go build settings
GO := go
GOFLAGS := -trimpath
LDFLAGS := -ldflags "-X main.Version=$(VERSION) -X main.Commit=$(COMMIT) -X main.BuildDate=$(BUILD_DATE) -s -w"

# Docker settings
# Personal fork: push to my own registry instead of the upstream one
REGISTRY ?= ghcr.io/myusername
IMAGE_NAME := $(REGISTRY)/$(PROJECT_NAME)
IMAGE_TAG ?= $(VERSION)

# Directories
BIN_DIR := bin
CMD_DIR := cmd
CHART_DIR := charts/hiclaw

# Tools
GOLANGCI_LINT_VERSION := v1.57.2

all: fmt vet lint test build

## build: Compile the project binaries
build:
	@echo "Building $(PROJECT_NAME) $(VERSION)..."
	@mkdir -p $(BIN_DIR)
	$(GO) build $(GOFLAGS) $(LDFLAGS) -o $(BIN_DIR)/$(PROJECT_NAME) ./$(CMD_DIR)/...
	@echo "Build complete: $(BIN_DIR)/$(PROJECT_NAME)"

## test: Run unit tests
test:
	@echo "Running tests..."
	$(GO) test ./... -v -race -coverprofile=coverage.out -covermode=atomic
	$(GO) tool cover -func=coverage.out

## test-integration: Run integration tests
test-integration:
	@echo "Running integration tests..."
	$(GO) test ./... -v -tags=integration -timeout=300s

## lint: Run golangci-lint
lint:
	@echo "Running linter..."
	@which golangci-lint > /dev/null 2>&1 || (echo "Installing golangci-lint $(GOLANGCI_LINT_VERSION)..." && \
		curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(shell go env GOPATH)/bin $(GOLANGCI_LINT_VERSION))
	golangci-lint run ./...

## fmt: Format Go source files
fmt:
	@echo "Formatting code..."
	$(GO) fmt ./...

## vet: Run go vet
vet:
	@echo "Running go vet..."
	$(GO) vet ./...

## clean: Remove build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BIN_DIR)
	@rm -f coverage.out
	@echo "Clean complete."

## docker-build: Build Docker image
docker-build:
	@echo "Building Docker image $(IMAGE_NAME):$(IMAGE_TAG)..."
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) \
		-t $(IMAGE_NAME):latest \
		.

## docker-push: Push Docker image to registry
docker-push: docker-build
	@echo "Pushing Docker image $(IMAGE_NAME):$(IMAGE_TAG)..."
	docker push $(IMAGE_NAME):$(IMAGE_TAG)
	docker push $(IMAGE_NAME):latest

## helm-lint: Lint Helm chart
helm-lint:
	@echo "Linting Helm chart..."
	helm lint $(CHART_DIR)

## generate: Run code generation (CRDs, mocks, etc.)
generate:
	@echo "Running code generation..."
	$(GO) generate ./...

## tidy: Tidy Go module dependencies
tidy:
	@echo "Tidying Go modules..."
	$(GO) mod tidy

## help: Display this help message
help:
	@echo "Usage: make [target]"
	@echo ""
