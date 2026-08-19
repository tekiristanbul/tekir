# changelog

release notes are written per version in [`docs/releases/`](docs/releases/). this
file is the index — it links each release and does not restate it.

versions follow [semantic versioning](https://semver.org/). the `+N` suffix in
`app/pubspec.yaml` is the shared android version code and ios build number, not
part of the released version.

| version | status | notes |
| --- | --- | --- |
| 0.4.3 | web published 2026-08-18; ios build 4 in review, android version code 4 on play | [`docs/releases/v0.4.3.md`](docs/releases/v0.4.3.md) |
| 0.4.2 | published 2026-08-17 | [`docs/releases/v0.4.2.md`](docs/releases/v0.4.2.md) |
| 0.4.1 | shipped, never tagged | covered by the 0.4.2 notes |
| 0.4.0 | shipped, never tagged | covered by the 0.4.2 notes |
| 0.3.0 | published 2026-08-08 | [`docs/releases/v0.3.0.md`](docs/releases/v0.3.0.md) |
| 0.2.0 | published; notes remain marked draft | [`docs/releases/v0.2.0.md`](docs/releases/v0.2.0.md), [smoke report](docs/releases/v0.2.0-smoke.md) |
| 0.1.0 | superseded | [github release](https://github.com/tekiristanbul/tekir/releases/tag/v0.1.0) |

## known gaps in this history

- `v0.4.0` and `v0.4.1` were released without git tags. the repository has tags
  `v0.1.0`, `v0.2.0`, `v0.3.0`, `v0.4.2`, `v0.4.3` only.
- the api and the flutter app are versioned independently and deploy
  independently, so a single row above does not describe one atomic release —
  see [`docs/architecture/backend.md`](docs/architecture/backend.md). what is
  actually running is read from `https://app.tekir.istanbul/version.json` and
  from the droplet, not from this file.
