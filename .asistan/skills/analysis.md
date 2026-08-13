# analysis

This applies when the workflow step you are executing is `analyze`. In any
other step, ignore this skill.

An `analyze` step produces understanding and a plan. It does not produce
code. Do not edit, add, or delete application code, tests, docs, or
configuration during analysis — a human reads your output and approves it
before anything is implemented, and this same workspace is what later gets
committed. Do not write `.asistan-commit-message` either.

`AGENTS.md` already governs how this repository wants work approached —
read it. This skill only says what the analyze step must produce.

## what to do

1. Read the GitHub issue and its existing discussion in your task text.
   That is the full issue context; you do not need to fetch anything from
   GitHub yourself.
2. Check the issue against `AGENTS.md`'s definition of ready. Anything it
   requires and the issue does not settle is a question, not something to
   invent an answer for.
3. Inspect the code the issue actually touches, in `app/` or `backend/`.
   Name real files and symbols in your output — an analysis that could
   have been written without opening the repository is not an analysis.
4. Check the existing tests and contracts around that code: what currently
   guarantees the behavior, and what would have to change.
5. Read the decisions that already bind this change, in `AGENTS.md`'s
   stated order: product docs (`docs/product/`), architecture docs
   (`docs/architecture/`: `api.md`, `backend.md`, `db.md`, `flutter.md`),
   `docs/design/` references, then the shipped implementation. Say plainly
   if the issue conflicts with one — name the document and the conflict.
   Do not quietly design around it.
6. Decide whether this change needs a new decision note, and where.
7. Write a short implementation plan.

## decision notes

`docs/architecture/` is one file per topic, not one file per decision —
follow that. A non-trivial tradeoff (a real alternative existed and one
was picked: library choice, schema shape, sync vs async, where a boundary
sits) gets a short note added to the relevant topic file. Routine changes
with no real alternative on the table get nothing.

A separate ADR is for consequential decisions with meaningful
alternatives and long-term tradeoffs — persistent data model semantics,
public API contracts, auth boundaries, component boundaries, expensive to
reverse technology choices. An ordinary bug fix is not one. If a change
is user-visible behavior or a data contract, the update belongs in the
product or architecture doc, per `AGENTS.md`, not in a new file.

## output

End your turn with exactly this block, in this order:

```
status: ready | needs-clarification

understanding:
...

questions:
...

existing decisions:
...

adr:
  required: yes/no
  reason: ...

plan:
1. ...
2. ...

risks:
...
```

For `risks`, classify the change as low/medium/high risk the way
`AGENTS.md` requires, and name any high-risk area it touches (migrations,
auth, precise location, media, destructive operations, breaking API
changes, notifications, user data).

Use `status: needs-clarification` when a product or architecture decision
the implementation depends on is missing or contradictory. Ask the
questions directly — you will be re-run with the answers folded into your
task. Use `status: ready` when the plan can be implemented as written, and
write `questions: none`. Never invent a product decision to avoid asking.
