# initial backlog draft

## goal

a first pass at the work implied by `docs/architecture/` and `docs/design/`, grouped by area. this is a draft for review — not a set of github issues yet, and not sequenced/estimated.

## decisions (draft items)

### blocking product decisions
these gate real implementation work and should be resolved before the item next to them is built:
- `needs_help` alert expiry duration ([[alerts]]) — blocks the "needs help" update path.
- status-update content vocabulary ([[updates]]) — blocks the update-composition screen and the `updates.comment` field shape.
- duplicate-cat merge mechanism ([[cats]]) — blocks anything beyond the basic "confirm it's a different cat" step in add-cat.
- cat-inactivity threshold ([[cats]]) — blocks the job that marks cats inactive.
- sms otp provider choice ([[backend]]) — blocks the auth/otp endpoints.
- k8s cluster + s3-compatible storage provider choice ([[backend]]) — blocks any real deployment.

### backend
- scaffold the go api service (handler → service → repository layers per [[backend]]).
- implement device registration + otp auth endpoints.
- implement cat endpoints (list, nearby, detail, create).
- implement update endpoints (list, create, media upload).
- implement follow + notification endpoints.
- stand up cnpg (postgres/postgis) and the notification worker on a cluster, once the provider is picked.

### flutter
- scaffold the app (`core/network`, `core/identity`, `core/router` per [[flutter]]).
- build the map screen with clustering.
- build cat detail, add update, add cat (location + details), discover, notifications, account, login screens against the wireframes in [[wireframes]].

### design
- take [[visual-direction]] into an actual figma file — the current wireframes and visual direction are both placeholders for this.

## open questions

see the blocking-decisions list above — none of them are resolved here, this backlog just tracks that they're pending.

## out of scope

- estimation, sequencing, or milestone assignment — this is a draft inventory, not a plan.
- non-mvp features (anything under "out of scope" in the relevant `docs/product/*.md` files).
