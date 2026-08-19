---
name: analyze-issue
description: Analyze one tekir issue against the real code, tests, and docs, then produce a short implementation plan without editing anything. Use when asked to analyze, scope, or plan an issue before implementation, or to decide whether an issue is ready to implement.
---

# analyze-issue

Produce understanding and a plan for one issue. Do not edit code, tests, docs,
or configuration in this skill — the plan is reviewed by a human before
anything is implemented.

`AGENTS.md` is the delivery contract and `GOVERNANCE.md` is the decision
contract. Read them; this skill only says what the analysis must produce.

## what to do

1. Read the issue and every existing comment, including the linked issues,
   pull requests, and documents they point at. Use `gh issue view <n>
   --comments` when the issue text is not already in the conversation.
2. Check the issue against the definition of ready in `AGENTS.md`. Anything it
   requires and the issue does not settle is a question, not something to
   answer by inventing a decision.
3. Inspect the code the issue actually touches, under `app/` or `backend/`.
   Name real files and symbols in the output — an analysis that could have
   been written without opening the repository is not an analysis.
4. Check the tests and contracts around that code: what currently guarantees
   the behavior, and what would have to change.
5. Read the decisions that already bind the change, in the order of authority
   `GOVERNANCE.md` states: the latest explicit product owner comment, the
   issue body and later maintainer comments, `docs/product/`,
   `docs/architecture/`, `docs/design/`, then the shipped implementation. Say
   plainly when the issue conflicts with one — name the document and the
   conflict rather than quietly designing around it.
6. Decide where a resulting decision is recorded, using the thresholds in
   `GOVERNANCE.md`: an adr in `docs/adr/` only for a durable decision with
   real alternatives, otherwise a line in the relevant topic document's
   `## decisions` section, otherwise nothing.
7. Check whether the requested behavior already exists. Read the code and run
   the relevant existing tests before claiming it does.
8. Write a short implementation plan.

## risk

Classify the change as low, medium, or high the way `AGENTS.md` requires, and
name any high-risk area it touches: migrations, authentication, authorization,
precise location, media handling, destructive operations, breaking api
changes, notifications, user data.

`low` means the change is narrow, easily reverted, covered by existing tests,
and touches none of those areas and no persistent data model. `high` is
anything touching one of them. Default to `medium` when not confident it is
`low`.

## output

Report in this order:

- **status** — `ready` or `needs-clarification`. Use `needs-clarification`
  when a product or architecture decision the implementation depends on is
  missing or contradictory. Ask those questions precisely instead of
  answering them.
- **risk** — `low`, `medium`, or `high`.
- **work required** — whether any code change is needed at all. Say `no` only
  when reading the code and running the relevant tests confirmed the behavior
  already exists; unsure is `needs-clarification`, never `no`.
- **understanding** — what the issue asks for, in terms of the real code.
- **questions** — unresolved decisions, or `none`.
- **existing decisions** — the documents and shipped behavior that bind this
  change, with conflicts named.
- **decision record** — whether an adr is required and why, or which topic
  document takes the `## decisions` line, or none.
- **plan** — numbered steps. When work is not required, describe what already
  exists and where instead.
- **risks** — the classification above, in prose, with high-risk areas named.
