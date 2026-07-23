# cats

## goal

define the core thing shown on the map: the cat.

## decisions

- a cat can have many photos over time. these are added through updates that include media, similar to how google maps handles location photos.
- a cat cannot have more than one location. instead, a cat belongs to an area — roughly 50 meters around a point. the same cat should not be added again under a different name inside that area.
- if two people add what looks like the same cat, nothing needs to happen the first time. later, duplicate cats should be mergeable — either by asking the user "is this the same cat you added?" or by a moderator merging them.
- cats should not be deletable. instead, a cat can become inactive — for example marked as lost, or if no one has posted an update for it in a long time.
- the minimum information to add a cat: name, a photo, and a location are all required.
- a cat can carry zero or more traits (e.g. friendly, playful) from a controlled vocabulary — not free text, and not a fixed/closed list either, since the vocabulary itself can still grow. traits describe the cat's profile and are separate from a status update's structured statuses ([[updates]]).
- traits are grouped (product-owner decision on issue #21/#23): personality, interaction with people, interaction with other animals, and physical characteristics are the proposed groups, so a future picker can present a grouped multi-select instead of one flat list. a trait's group is mutable metadata, like its display label — moving a trait to a different group is a data change, not a migration.
- the cat-detail screen shows only a short trait summary (the first few, then a "+n more" that expands the full list in place) rather than an unbounded chip list — this is a display rule for issue #23, not a change to the underlying vocabulary.
- a future add/edit-cat picker groups traits by their group and supports search once the vocabulary grows large enough that a flat list stops being easy to scan; that picker's own visual design and interaction details aren't decided here — the prototype/implementation define those when that flow is actually built.

## open questions

- does the most-liked or most-commented photo become the cat's main photo? not decided.
- how exactly duplicate cats get merged (user prompt vs. moderator) is not settled. flagged as a later topic.
- how long without an update before a cat is marked inactive is not defined here. a "1 year" idea was raised in [[updates]] (open question), but not confirmed as the rule.
- the trait vocabulary's specific labels and grouping are proposed but pending product-owner review (see [[db]]).

## out of scope

- deleting cats outright.
