.PHONY: build test vet run lint

build:
	go build -o bin/swe-kitty-broker ./cmd/swe-kitty-broker

test:
	go test ./...

vet:
	go vet ./...

run:
	go run ./cmd/swe-kitty-broker up --local

lint:
	golangci-lint run
