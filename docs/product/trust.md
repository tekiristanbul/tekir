# trust

## goal

define what makes the product's information reliable without making contribution unnecessarily difficult.

## decisions

- the guiding principle is: contribution should be easier than avoiding every possible mistake.
- guests (not logged in) can view cats on the map, read updates and comments, and see labels.
- guests can follow/favorite a cat and post a text-only update without logging in.
- phone verification is required for users who add photos or videos, and for users who add a new cat, because a photo is required when a cat is first added.
- creating a needs-help alert ([[alerts]]) always requires being logged in because false or spammy alerts have an outsized cost.
- ordinary users cannot delete cats; cat deletion is an admin action.
- users may correct or remove their own update only during the short grace period defined by the update experience ([[updates]]). after that, newer updates provide the current state.
- the product should not block cat creation with duplicate-detection warnings. duplicate correction and merging happen later through admin or moderator tools.
- trust is expressed through visible, public contribution history rather than follower counts or people-centric popularity.

## open questions

- how a "trusted contributor" is defined is not decided.
- the exact update correction/removal grace period is not decided.

## out of scope

- people-following.
- public popularity ranking or leaderboards in mvp.
