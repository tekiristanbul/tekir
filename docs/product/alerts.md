# alerts

## goal

define how cats that need help get noticed.

## decisions

- "needs help" is a special alert, not a normal status update. it can notify the users who follow that cat.
- alerts end automatically. this is intentional, to avoid clutter.
- creating an alert requires being logged in, same as posting an update.
- there is no "alert resolved" state. the product's job ends at notifying followers. after a set time, the alert is simply deleted.

## open questions

- how long an alert should last is not decided. ideas ranged from about 1 day (low traffic) to as short as 3 hours (high traffic).
- should "needs help" stay a separate alert, or become a special type of update? this is not settled — see [[principles]].

## out of scope

- tracking or marking whether an alert was resolved.
