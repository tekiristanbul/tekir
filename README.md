# tekir

tekir — cats of istanbul — is a community-driven mobile app for tracking istanbul's street cats: where a cat usually is, its latest status, and whether it needs help. canonical domain: [tekir.istanbul](https://tekir.istanbul).

this repo holds the project's foundation: a go api, a flutter app, and the postgres/postgis database behind them. the mvp is in progress: the api serves a read-only nearby-cats endpoint (`GET /v1/cats`) and the flutter app renders it on a map; see [`docs/backlog.md`](docs/backlog.md) for what's next.

- [`docs/brand.md`](docs/brand.md) — canonical product naming.
- [`docs/product/`](docs/product/) — product vision, principles, and per-topic decisions (map, cats, updates, trust, notifications, community, discovery, users).
- [`docs/architecture/`](docs/architecture/) — mvp api, db, flutter, and backend design.
- [`docs/design/`](docs/design/) — low-fi wireframes and visual direction.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — commit conventions and where new docs belong.

## project structure

```
backend/            go api (cmd/api), seed command (cmd/seed), migrations and queries (db/)
app/                flutter app (web target for now)
docker-compose.yml  postgres + postgis + the api, for local development
```

## prerequisites

- [asdf](https://asdf-vm.com/) (recommended) — `.tool-versions` at the repo root pins the go and flutter versions this project uses. run `asdf install` from the repo root to get both, or install them yourself matching those versions.
- docker + docker compose

## first run

```bash
docker compose up -d
cd backend && make migrate-up
cd backend && make seed   # optional, repeatable fixture data
```

this starts postgres (with postgis) and the api. check it's up:

```bash
curl http://localhost:8080/healthz   # liveness
curl http://localhost:8080/readyz    # readiness (checks the database)
```

if port 5432 or 8080 is already taken on your machine, override the host ports:

```bash
POSTGRES_PORT=5433 API_PORT=8081 docker compose up -d
```

## backend

see [`backend/Makefile`](backend/Makefile) for all commands. the common ones:

```bash
cd backend
make run             # go run ./cmd/api (needs DATABASE_URL set, e.g. via docker compose postgres)
make build           # build the api binary
make test            # go test ./...
make lint            # golangci-lint
make fmt             # gofmt check
make migrate-up      # apply migrations (goose)
make migrate-down    # roll back one migration
make migrate-status  # show migration state
make seed            # load repeatable fixture data
make sqlc            # regenerate query code after editing db/queries/*.sql
```

`goose` and `sqlc` are pinned as go tool dependencies (`go.mod`'s `tool` directive) — `go tool goose`/`go tool sqlc` resolve and build them automatically, no separate install needed beyond go itself.

migrations live in `backend/db/migrations`, queries in `backend/db/queries`. `workspace_pings` is a smoke-test table proving migrations/seed/postgis work end to end — it isn't part of the product schema. `cats` is the first product table, backing the nearby-cats endpoint (see [`docs/architecture/db.md`](docs/architecture/db.md) for both).

## flutter app

the map screen needs a google maps javascript api key (`google_maps_flutter`, see [`docs/architecture/flutter.md`](docs/architecture/flutter.md)). it's never committed — `web/index.html` carries a placeholder token that `scripts/run_web.sh` substitutes at run time, restoring the placeholder on exit:

```bash
cd app
flutter pub get
cp .env.local.example .env.local   # once — fill in GOOGLE_MAPS_API_KEY
./scripts/run_web.sh
```

this always runs on a fixed port (`http://localhost:5050`), so the dev key can be restricted in the google cloud console to exactly that origin — restrict it to the "maps javascript api" only, and use a separate key for production (restricted to the real domain, with its own quota/billing alert). without a key, `GoogleMap` won't render (only the web target is set up — see below).

running some other way (`flutter run -d chrome` directly, `flutter build web`) still needs the key injected into `web/index.html` first, by hand or by adapting the script.

the app points at `http://localhost:8080` by default; override with `--dart-define=API_BASE_URL=...` if the api runs elsewhere (`run_web.sh` forwards extra args to `flutter run`, so `./scripts/run_web.sh --dart-define=API_BASE_URL=...` works).

```bash
cd app
flutter analyze
dart format --output=none --set-exit-if-changed .
flutter test
```

only the web target is set up for now (see [`docs/architecture/flutter.md`](docs/architecture/flutter.md)); android/ios are added once there's a device/emulator workflow to test them against.

## ci

github actions (`.github/workflows/ci.yml`) runs the same checks on every push/pr: backend build/vet/lint/fmt/test against a real postgres+postgis service container (migrations included), and flutter format/analyze/test.
