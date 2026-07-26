# tekir

tekir — cats of istanbul — is a community-driven mobile app for tracking istanbul's street cats: where a cat usually is, its latest status, and whether it needs help. canonical domain: [tekir.istanbul](https://tekir.istanbul).

this repository contains the go api, flutter app, postgres/postgis schema, product contract, architecture, and approved prototype. the mvp is under active development; github issue [#45](https://github.com/tekiristanbul/tekir/issues/45) tracks the implementation sequence.

- [`docs/brand.md`](docs/brand.md) — canonical product naming.
- [`docs/product/`](docs/product/) — approved product decisions.
- [`docs/architecture/`](docs/architecture/) — mvp api, database, flutter, and backend design.
- [`docs/design/`](docs/design/) and [`prototype/`](prototype/) — approved design references.
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — contribution policy and local validation.
- [`SECURITY.md`](SECURITY.md) — private vulnerability reporting.
- [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md) — community standards.
- [`LICENSE`](LICENSE) — mit license.

## community and contributions

tekir is in early development.

- reproducible bug reports are accepted through the github bug report form.
- ideas, feature proposals, ux suggestions, and questions belong in [github discussions](https://github.com/tekiristanbul/tekir/discussions), not issues.
- external implementation contributions are accepted only for open issues labeled [`help wanted`](https://github.com/tekiristanbul/tekir/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22help%20wanted%22).
- comment on a `help wanted` issue and wait for maintainer acknowledgement before starting.
- unsolicited pull requests, feature implementations, and product or ux changes are not accepted.

see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the complete workflow.

## project structure

```
backend/            go api (cmd/api), seed command (cmd/seed), migrations and queries (db/)
app/                flutter app (web target for now)
prototype/          approved local interactive mvp reference
docker-compose.yml  postgres + postgis + the api, for local development
```

## prerequisites

- [asdf](https://asdf-vm.com/) (recommended) — `.tool-versions` at the repo root pins the go and flutter versions this project uses. run `asdf install` from the repo root to get both, or install matching versions yourself.
- docker + docker compose

## first run

```bash
docker compose up -d
cd backend && make migrate-up
cd backend && make seed   # optional, repeatable fixture data
```

this starts postgres with postgis and the api. check health:

```bash
curl http://localhost:8080/healthz
curl http://localhost:8080/readyz
```

if port 5432 or 8080 is already taken:

```bash
POSTGRES_PORT=5433 API_PORT=8081 docker compose up -d
```

## backend

see [`backend/Makefile`](backend/Makefile) for all commands. common commands:

```bash
cd backend
make run
make build
make test
make lint
make fmt
make migrate-up
make migrate-down
make migrate-status
make seed
make sqlc
```

`goose` and `sqlc` are pinned as go tool dependencies. migrations live in `backend/db/migrations`, and queries live in `backend/db/queries`.

## flutter app

the map screen needs a google maps javascript api key. it is never committed. `app/web/index.html` contains a placeholder that `app/scripts/run_web.sh` substitutes at runtime and restores on exit:

```bash
cd app
flutter pub get
cp .env.local.example .env.local
./scripts/run_web.sh
```

restrict the development key to `http://localhost:5050` and the maps javascript api. use a separate restricted production key with its own quota and billing alert.

the app points at `http://localhost:8080` by default. override it with `--dart-define=API_BASE_URL=...`.

```bash
cd app
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

only the web target is currently configured.

## ci

github actions in `.github/workflows/ci.yml` run backend build, vet, lint, format, migrations, and tests against postgres/postgis, plus flutter format, analyze, and tests on every push and pull request.
