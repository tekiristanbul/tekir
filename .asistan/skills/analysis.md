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
risk: low | medium | high
work_required: yes | no

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

`risk:` is the machine-readable counterpart to that `risks:` prose — a
single word, read by tooling to decide whether a human needs to look at
this report before implementation starts. `low` is a claim that they can
skip that read, so set it only when the change is narrow, easily
reverted, well covered by existing tests, and touches none of
`AGENTS.md`'s high-risk areas (migrations, authentication, authorization,
precise location, media handling, destructive operations, breaking API
changes, notifications, user data) and no persistent data model. `high`
is anything touching one of those areas. Default to `medium` whenever
you're not confident it's `low` — `medium` is the safe answer, not a
last resort.

`work_required:` says whether the issue needs any code change at all.
Before writing a plan, check whether the requested behavior is already
implemented: read the code and run the relevant existing tests. Write
`no` only when that check actually confirms it — not when the behavior
merely looks close or you haven't run the tests. `work_required: no`
requires `status: ready`; if you're unsure whether it's already done,
that's `status: needs-clarification`, never `work_required: no`. When it
is `no`, write `plan` as a description of what already exists and where,
not a list of steps, and write `risks` as none. Every other case is
`work_required: yes`.

Use `status: needs-clarification` when a product or architecture decision
the implementation depends on is missing or contradictory. Ask the
questions directly — you will be re-run with the answers folded into your
task. Use `status: ready` when the plan can be implemented as written, and
write `questions: none`. Never invent a product decision to avoid asking.
