.PHONY: build test vet run lint

build:
	go build -o bin/conduit-broker ./cmd/conduit-broker

test:
	go test ./...

vet:
	go vet ./...

run:
	go run ./cmd/conduit-broker up --local

lint:
	golangci-lint run
