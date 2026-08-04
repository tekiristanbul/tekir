# notifications

## goal

define why and how users return to cats they care about without turning tekir into a people-centric social network.

## decisions

- users follow or favorite cats, not people.
- the primary value of following is saving a cat so the user can find it again.
- followed cats are shown in a list ordered by most recent activity.
- following a cat requires an authenticated account.
- notification permission is requested only after a user follows a cat or otherwise opts into notifications, not on first app launch.
- notifications are not based on device location or distance.
- in mvp, only a newly-created active needs-help update for a followed cat triggers a push notification. this trigger rule is unchanged by the 0.2 simplified help contract ([[alerts]], issue #100); notification copy is already category-free and stays as-is, only the push data payload's `category` key is dropped in 0.2.
- ordinary `seen`, `fed`, `water_provided`, comment, and media activity do not trigger push notifications in mvp.
- public user profiles may show contribution history, including which cats the user saw, fed, gave water to, photographed, or added.
- badges are a secondary profile element near the profile header or avatar and follow the vocabulary and thresholds in [[badges]].
- leaderboards and points are not part of mvp.

## open questions

- none for mvp.

## out of scope

- following people.
- notifications based only on location.
- notification delivery for every ordinary update.
- leaderboards, points, streaks, or daily missions.
