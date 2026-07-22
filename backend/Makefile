.PHONY: run build test lint fmt sqlc migrate-up migrate-down migrate-status seed

DATABASE_URL ?= postgres://catsofistanbul:catsofistanbul@localhost:5432/catsofistanbul?sslmode=disable

run:
	go run ./cmd/api

build:
	go build -o bin/api ./cmd/api

test:
	go test ./...

lint:
	golangci-lint run ./...

fmt:
	gofmt -l .
	test -z "$$(gofmt -l .)"

sqlc:
	go tool sqlc generate

migrate-up:
	go tool goose -dir db/migrations postgres "$(DATABASE_URL)" up

migrate-down:
	go tool goose -dir db/migrations postgres "$(DATABASE_URL)" down

migrate-status:
	go tool goose -dir db/migrations postgres "$(DATABASE_URL)" status

seed:
	DATABASE_URL="$(DATABASE_URL)" go run ./cmd/seed
