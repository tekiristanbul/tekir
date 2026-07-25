# vision

## goal

define what tekir is, in one sentence, and why it exists.

## decisions

- one-sentence definition: an app where a user can see cats nearby, add photos or videos to a cat, and post structured status updates (`seen`, `fed`, `water_provided`) with an optional free-text comment; an update requires at least one structured status, so a comment alone is not valid. behavior such as "friendly" or "playful" is not a permanent cat-profile attribute — it's an observation from a moment and a person, mentionable only in a status update's comment ([[updates]]). a user can also post a needs-help update, which expires automatically after exactly 72 hours and remains in the cat's history without active emphasis once expired.
- problem it solves: it makes the city more interesting for tourists, who can share photos of cats they meet. it also makes a cat that needs help visible on the map, so people who want to help can find it.
- why a user opens the app for the first time: curiosity about which cats are nearby. out of curiosity, a user can go find a cat, take its photo, and upload it. this is fun and engaging.
- why a user opens the app again the next day: to check on nearby cats. did they get fed or given water? was a new cat added or named?
- mvp success is measured by useful, recurring care information rather than cat-count growth alone. the primary signals are:
  - the percentage of visible cats that receive at least one update.
  - the percentage of cats that receive another update within 30 days.
  - weekly active authenticated contributors.
  - the percentage of active needs-help updates viewed by at least one follower.
  - the duplicate-cat rate, used as a quality signal rather than a growth goal.
- reaching approximately 1,000 cat records is a scale milestone, not a sufficient success definition by itself.

## open questions

- none for mvp.

## out of scope

- revenue, advertising, or growth-loop targets as mvp success criteria.
