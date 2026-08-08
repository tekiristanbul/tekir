# tekir

**cats of istanbul**

tekir is an open-source, map-first application for discovering and caring for istanbul’s street cats.

[**open the app →**](https://app.tekir.istanbul) · [website](https://tekir.istanbul)

> **0.3 is live.** backend and web are deployed to production; ios submission is in progress, android store publication remains pending. release notes live in [`docs/releases/`](docs/releases/).

---

## what tekir does

tekir helps people understand and continue the shared care of a street cat:

- where the cat is usually seen
- when it was last seen
- whether food or water was recently provided
- whether it currently needs help
- how people nearby can continue caring for it together

tekir is not a social network, animal charity, veterinary service, or pet product.

## current status

- mvp product contract: complete
- 0.1 (web): superseded — see [release notes](https://github.com/tekiristanbul/tekir/releases/tag/v0.1.0)
- 0.2: web and backend published — see [release notes](https://github.com/tekiristanbul/tekir/releases/tag/v0.2.0)
- 0.3: backend and web published, deployed to production — see [`docs/releases/v0.3.0.md`](docs/releases/v0.3.0.md)
- ios: submission in progress, not yet in review
- android: built from this codebase, store release pending a production upload keystore

current implementation work is tracked through individual maintainer-created issues, not a single tracker.

## open-source contribution policy

tekir uses a controlled workflow while the product and architecture are still being implemented.

- reproducible bug reports are welcome
- high-level product and community ideas belong in [github discussions](https://github.com/tekiristanbul/tekir/discussions)
- concrete feature requests and implementation work are handled through maintainer-created issues
- implementation contributions are accepted only through maintainer-created issues labeled [`help wanted`](https://github.com/tekiristanbul/tekir/issues?q=is%3Aissue%20state%3Aopen%20label%3A%22help%20wanted%22)
- comment on the issue and wait for maintainer acknowledgement before starting
- unsolicited pull requests are not accepted

see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the complete workflow.

## repository guide

| path | purpose |
| --- | --- |
| [`app/`](app/) | flutter client |
| [`backend/`](backend/) | go api, database migrations, queries, and seed command |
| [`docs/product/`](docs/product/) | product contract |
| [`docs/architecture/`](docs/architecture/) | technical contracts |
| [`docs/design/`](docs/design/) | design references |
| [`website/`](website/) | public landing page |

## development

start the local postgres/postgis and api services:

```text
docker compose up -d
```

see [`DEVELOPMENT.md`](DEVELOPMENT.md) for prerequisites, migrations, seed data, backend and flutter setup, local configuration, validation, ci behavior, and troubleshooting.

## community and policies

- [contributing](CONTRIBUTING.md)
- [code of conduct](CODE_OF_CONDUCT.md)
- [security](SECURITY.md)
- [license](LICENSE)
- [github discussions](https://github.com/tekiristanbul/tekir/discussions)
- [open issues](https://github.com/tekiristanbul/tekir/issues)

## contact

- general: `hello@tekir.istanbul`
- support: `support@tekir.istanbul`
- privacy: `privacy@tekir.istanbul`
- security: `security@tekir.istanbul`
