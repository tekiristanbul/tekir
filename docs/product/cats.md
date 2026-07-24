# cats

## goal

define the core thing shown on the map: the cat.

## decisions

- a cat can have many photos and videos over time. media is added through updates and forms a place-style gallery, similar to how map products collect location media.
- a cat cannot have more than one location. instead, a cat belongs to an area — roughly 50 meters around a point.
- adding a cat should not be blocked by duplicate-detection warnings. if two people add what looks like the same cat, contribution continues; duplicate cats can be merged later by an admin or moderator workflow.
- cats can be deleted only by admins. ordinary users cannot delete a cat.
- the minimum information to add a cat is a photo and a location. a user-provided name is optional.
- when no name is provided, the product may assign a friendly random name. photo-based ai name suggestions are a later enhancement, not an mvp requirement.
- permanent personality traits are not collected during cat creation and are not treated as authoritative cat-profile data. different people may experience the same cat differently.
- behavioral observations such as playful, shy, or friendly belong in update comments ([[updates]]). future ai-generated summary labels may be derived from accumulated observations, but they must remain summaries rather than a single user's permanent classification.
- strongly identifying physical information should help users recognize that they opened the correct cat.
- the initial main cat image may come from a curated set of city-cat images. allowing community-uploaded media to become the main profile image is a later enhancement.

## open questions

- how duplicate cats are merged is not settled.
- how a community-uploaded media item becomes the main profile image is not decided.
- how long without an update before a cat is marked inactive is not defined here.

## out of scope

- automatic ai naming in mvp.
- user-controlled cat deletion.
- permanent user-selected personality traits.
