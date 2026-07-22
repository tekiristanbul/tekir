# cats

## goal

define the core thing shown on the map: the cat.

## decisions

- a cat can have many photos over time. these are added through updates that include media, similar to how google maps handles location photos.
- a cat cannot have more than one location. instead, a cat belongs to an area — roughly 50 meters around a point. the same cat should not be added again under a different name inside that area.
- if two people add what looks like the same cat, nothing needs to happen the first time. later, duplicate cats should be mergeable — either by asking the user "is this the same cat you added?" or by a moderator merging them.
- cats should not be deletable. instead, a cat can become inactive — for example marked as lost, or if no one has posted an update for it in a long time.

## open questions

- what is the minimum information needed to add a cat? not answered.
- does the most-liked or most-commented photo become the cat's main photo? not decided.
- how exactly duplicate cats get merged (user prompt vs. moderator) is not settled. flagged as a later topic.
- how long without an update before a cat is marked inactive is not defined here. a "1 year" idea was raised in [[updates]] (open question), but not confirmed as the rule.

## out of scope

- deleting cats outright.
