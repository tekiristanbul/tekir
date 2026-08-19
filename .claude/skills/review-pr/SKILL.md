---
name: review-pr
description: Technically review one tekir pull request against its linked issue — correctness, scope, data safety, compatibility, security, privacy, tests, docs, and cross-document semantic consistency — and report blocking versus non-blocking findings without approving or merging. Use when asked to review a pull request, a branch, or a diff in this repository.
---

# review-pr

First-pass technical review of one pull request. Report problems; do not fix
them, and do not approve, merge, or mark anything ready. A human decides.

`AGENTS.md` defines what the change was required to do and what evidence it
owes. `GOVERNANCE.md` defines who approves what. Read both before judging.

## read the real change

Read the actual diff, not the description. Use `gh pr view <n>` and
`gh pr diff <n>`, or `git diff` against the base branch for a local branch,
plus the linked issue and every existing comment.

Never claim a check passed without running it. When the pull request's own
validation evidence is missing, partial ("the new test passes" is not "the
test file passes"), or does not match the diff, that is a blocking finding,
not a detail. Run the repository's validation commands yourself when the
working tree allows it, and say which ones you ran and which you could not.

## what to check

1. **Scope and acceptance criteria.** The diff satisfies the issue and does
   not invent product behavior, expand scope, or carry unrelated cleanup.
2. **Correctness and invariants** across code, api contracts, database schema,
   migrations, tests, and documentation.
3. **Cross-document semantic consistency** for every product or architecture
   concept the diff changes:
   - derive the semantic dependency set from the concepts the diff changes,
     not only from the files it touches or the issue names
   - inspect the `docs/product/` files, and the `docs/architecture/` files
     where relevant, that define or constrain those concepts
   - verify complete invariants: required versus optional fields,
     prerequisites and minimum valid state, rule versus exception
     relationships, authentication and authorization boundaries, concept
     ownership across documents, lifecycle, expiry, history and visibility
     semantics, and whether something is implemented, accepted, planned, or
     pending
   - report semantic contradictions, weakened invariants, omitted material
     constraints, and exceptions tied to the wrong baseline rule — not
     wording differences alone
   - a statement that is locally correct is still a finding when it is
     semantically incomplete across that dependency set
4. **Migrations and destructive changes.** Existing-data safety, explicit
   failure behavior, transactional boundaries, rollback or recovery, silent
   data-loss risk.
5. **Api changes.** Compatibility with released clients, stable ordering,
   pagination, validation, error contracts.
6. **Security and privacy** where applicable: authentication, authorization,
   secrets, precise location, media, user data, abuse, retention, rate limits.
7. **Runtime behavior** where relevant: concurrency, idempotency, time
   handling, deterministic tests, performance-sensitive queries,
   observability.
8. **Evidence.** Validations run were the right ones for the paths changed,
   and user-visible changes carry screenshots or a demo covering the main
   state and applicable loading, empty, error, and not-found states.
9. **Decision records.** A durable decision with real alternatives has an adr
   in this pull request per `GOVERNANCE.md`; a smaller tradeoff has a line in
   the relevant topic document's `## decisions` section. Call out a missing or
   inconsistent record, and check the record matches what the diff actually
   does.

## output

- **blocking findings** — correctness, data loss, security, contract,
  acceptance-criteria, semantic contradiction, weakened invariant, material
  omission, wrong-baseline exception, or missing/false validation evidence.
  Write `none` when empty.
- **non-blocking findings** — maintainability, clarity, performance, or
  follow-up improvements that do not block merge. Write `none` when empty.
- **open questions** — missing decisions or evidence, asked precisely. Write
  `none` when empty.
- **residual risks** — what remains uncertain after the review, and which
  areas you are least confident about. Recommend deeper human technical review
  when a material area is one of them.
- **human review needed** — which humans must look at this before merge, with
  a reason grounded in the diff. Changes to user behavior, user-facing turkish
  copy, visual output, or ux interaction need the product owner; documentation
  maintenance that only synchronizes an already accepted decision does not.
  Decide from the repository context rather than writing "if required".
- **evidence** — the files you read and the commands you ran.

Never end with `approved` or `lgtm`.
