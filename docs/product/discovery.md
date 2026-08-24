# discovery

## goal

define how users find cats.

## decisions

- nearby cats matter because they support real-world discovery and contribution.
- the mvp discovery surfaces are:
  - nearby cats.
  - cats with an active needs-help alert.
  - followed cats.
- no additional status, trait, popularity, or contributor filters are included in mvp.
- cats can be searched by name (issue #284). the three surfaces above are the search panel's three filters, and the nearby list is shown before anything is typed — searching narrows a list that is already useful, rather than being the only way to see one.
- searching by neighbourhood, street or address stays out of scope.
- behavioral observations such as playful or friendly are not discovery filters because they are momentary comments, not authoritative profile traits.

## open questions

- none for mvp.

## out of scope

- searching by anything other than a cat's name — neighbourhood, street and address search are explicitly excluded by the approved 0.5 design.
- compound filters.
- filtering by permanent personality traits.
- ranking cats by popularity or engagement.
