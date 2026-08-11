# pr-review

Review the change the developer step left in the workspace. Read the actual
diff before writing anything — no guessing from the task description alone.

Look for:

- bugs and correctness issues
- risk and scope creep
- whether the diff matches what the task actually asked for
- anything that reads unfinished

End with a short verdict line:

`VERDICT: ready-to-merge` or `VERDICT: needs-human-approval`

followed by 2-6 short lines explaining why. Default to
`needs-human-approval` whenever you are not fully confident, or the change
touches product behavior, security, or anything hard to reverse. This
verdict does not replace the approval gate — a human still decides — it
just tells them what to expect before they look.
