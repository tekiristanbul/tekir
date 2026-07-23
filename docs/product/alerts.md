# alerts

## goal

define how cats that need help get noticed.

## decisions

product-owner decision on issue #4 (approved for mvp):

- "needs help" is represented as an update subtype, not a fully separate structure — it carries its own lifecycle fields (see [[updates]]). this also resolves the conflict [[principles]] used to flag: it's a special kind of update, not a separate alert type.
- the fixed mvp help-category vocabulary: injured/sick, food needed, water needed, unsafe location, trapped.
- an alert expires automatically after a fixed 72 hours. this is intentional, to avoid clutter.
- creating an alert requires being logged in, same as posting an update.
- there is no "resolve" action in the mvp — the product's job ends at notifying followers. after 72 hours, the alert simply expires.
- notifications for an alert go to that cat's followers only (same mechanism as a regular update, see [[notifications]]).
- an active alert is emphasized on the map and cat detail; an expired alert stays in the cat's history without that emphasis.

## open questions

- none currently open. future versions may introduce manual resolution or different expiry rules if user feedback indicates a need.

## out of scope

- tracking or marking whether an alert was resolved — no resolve action exists in the mvp.
