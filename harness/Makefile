.PHONY: build test vet run lint

build:
	go build -o bin/swe-kitty-harness ./cmd/swe-kitty-harness

test:
	go test ./...

vet:
	go vet ./...

run:
	go run ./cmd/swe-kitty-harness up --local

lint:
	golangci-lint run
