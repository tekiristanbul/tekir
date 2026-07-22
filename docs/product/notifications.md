# notifications

## goal

define why and how users get notified, so they come back to the app.

## decisions

- notifications are sent to followers when a followed cat gets an update.
- users opt into notifications by following/favoriting a cat, not on first app launch. this keeps the permission request small and relevant.
- nearby alerts are only sent to users who follow that cat — not based on distance alone.
- notifications are not based on location.
- too many notifications is not expected to be a problem, since notifications only relate to what the user follows.

## open questions

- none raised in this part of the workshop.

## out of scope

- notifications based on location.
