.PHONY: build test release

build:
	go build -o bin/runctl ./cmd/runctl

test:
	go test ./...

release:
	mkdir -p dist
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/runctl-linux-amd64 ./cmd/runctl
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o dist/runctl-linux-arm64 ./cmd/runctl
	cd dist && shasum -a 256 runctl-linux-* > checksums.txt
