# verification

evidence before claims, always.

## the rule

no completion or correctness claim without having just run the command
that proves it, in this session, and read its full output. "should work",
"looks right", and a previous run don't count.

before saying a change works, a test suite passes, or a bug is fixed:

1. identify what command actually proves it (`make test`, `make lint`,
   `flutter test`, or reproducing the specific reported case)
2. run the full command, fresh, right now
3. read the full output — exit code, failure count, actual error text
4. only then state the result — what you saw, not what you expected to see

## applies to

- "tests pass" — full output showing it, not "should pass now"
- "bug fixed" — re-run the original failing case; a code change isn't a fix
  until you've watched the symptom go away
- "lint/build clean" — the actual command's output, not a partial check
- reviewing another step's work — read the real diff and its test output,
  don't reason from the task description alone

## red flags — stop, go verify, then continue

- "should work now", "looks correct", "probably fine"
- satisfaction before having run anything
- about to commit, push, hand off, or approve without a fresh check
- reusing a stale/previous run's result instead of a fresh one

a claim made without having just run the proof is a guess wearing a
claim's clothes.
