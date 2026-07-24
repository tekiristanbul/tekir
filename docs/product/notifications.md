# notifications

## goal

define why and how users return to cats they care about without turning tekir into a people-centric social network.

## decisions

- users follow or favorite cats, not people.
- the primary value of following is saving a cat so the user can find it again.
- followed cats are shown in a list ordered by most recent activity.
- users opt into notifications through following/favoriting a cat, not on first app launch.
- nearby alerts are sent only in relation to followed cats, not based on distance alone.
- notifications are not based on location.
- public user profiles may show contribution history, including which cats the user saw, fed, gave water to, photographed, or added.
- badges are a secondary profile element near the profile header or avatar. they celebrate real contribution rather than follower counts.
- leaderboards are not part of mvp.

## open questions

- which followed-cat update types should create a notification is not decided. avoiding notification fatigue is more important than notifying for every `seen` update.
- the initial badge vocabulary and thresholds are not decided.

## out of scope

- following people.
- notifications based only on location.
- leaderboards in mvp.
