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
- managed postgres provider + managed s3-compatible storage provider choice ([[backend]]) — blocks any real deployment. kubernetes is explicitly deferred, not part of this decision.

### backend
- scaffold the go api service (handler → service → repository layers per [[backend]]).
- implement device registration + otp auth endpoints (server-issued device token, refresh token).
- implement cat endpoints (list, nearby, detail, create).
- implement update endpoints (list, create, media upload).
- implement follow + notification endpoints.
- stand up managed postgres/postgis and deploy the api + notification worker containers (single vm or managed container platform), once a provider is picked.

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
- staying a live, maintained list: once an item here is ready to act on, it becomes a github issue tracked in github projects. this file is the reasoning behind the backlog, not the backlog itself — don't expect it to reflect current status.
