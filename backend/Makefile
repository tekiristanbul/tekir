.PHONY: run run-notifier build test lint fmt sqlc migrate-up migrate-down migrate-status seed

DATABASE_URL ?= postgres://catsofistanbul:catsofistanbul@localhost:5432/catsofistanbul?sslmode=disable
export DATABASE_URL

# local dev only — never reuse this value outside a throwaway local
# database; a real deployment sets its own JWT_SIGNING_KEY as a secret.
JWT_SIGNING_KEY ?= local-dev-only-not-a-secret
export JWT_SIGNING_KEY

run:
	go run ./cmd/api

run-notifier:
	go run ./cmd/notifier

build:
	go build -o bin/api ./cmd/api
	go build -o bin/notifier ./cmd/notifier

test:
	go test ./...

lint:
	go tool golangci-lint run ./...

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
	go run ./cmd/seed
