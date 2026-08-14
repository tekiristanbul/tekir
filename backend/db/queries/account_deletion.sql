-- issue #242: in-app account deletion (apple guideline 5.1.1(v)). Every
-- statement here is scoped to one account and runs inside a single
-- transaction (Store.DeleteAccount), in foreign-key-safe order. Deletion is
-- terminal: there is no deactivate/restore state anywhere in this file.
--
-- What "the account's data" means here follows the product decision on
-- #242: the account row and its identity, its auth state, its follows, the
-- updates it authored, the media it uploaded, and the cats it created —
-- and, because a cat cannot survive without its owner in 0.4, everything
-- attached to those cats, including other accounts' contributions to them
-- (explicitly accepted in the issue; owner transfer is out of scope).

-- name: ListAccountObjectKeys :many
-- The object-store keys to delete after the transaction commits. Collected
-- first, while the rows still exist: once the media rows are gone there is
-- nothing left to derive them from, and an orphaned object is a privacy
-- problem, not just wasted storage.
select m.object_key
from media m
where m.uploaded_by_user_id = sqlc.arg(user_id)
   or m.id in (
     select cm.media_id from cat_media cm
     join cats c on c.id = cm.cat_id
     where c.created_by_user_id = sqlc.arg(user_id)
   );

-- name: DeleteAccountNotifications :exec
-- A notification is reachable through three different roots this deletion
-- removes: the account's own devices, its cats, and the updates it wrote.
delete from notifications n
where n.device_id in (select d.id from devices d where d.user_id = sqlc.arg(user_id))
   or n.cat_id in (select c.id from cats c where c.created_by_user_id = sqlc.arg(user_id))
   or n.update_id in (select u.id from updates u where u.author_user_id = sqlc.arg(user_id));

-- name: DeleteAccountOutbox :exec
-- Queued fan-out for updates/cats that are about to stop existing. Dropped
-- rather than processed: delivering a push for a deleted cat would deep-link
-- into a 404.
delete from notification_outbox o
where o.cat_id in (select c.id from cats c where c.created_by_user_id = sqlc.arg(user_id))
   or o.update_id in (select u.id from updates u where u.author_user_id = sqlc.arg(user_id));

-- name: DeleteAccountUpdateStatuses :exec
delete from update_statuses s
where s.update_id in (
  select u.id from updates u
  where u.author_user_id = sqlc.arg(user_id)
     or u.cat_id in (select c.id from cats c where c.created_by_user_id = sqlc.arg(user_id))
);

-- name: DeleteAccountUpdates :exec
-- Both roots at once: what the account wrote anywhere, and everything
-- written on the cats it owned.
delete from updates u
where u.author_user_id = sqlc.arg(user_id)
   or u.cat_id in (select c.id from cats c where c.created_by_user_id = sqlc.arg(user_id));

-- name: DeleteAccountFollows :exec
-- The account's own follows, and everyone else's follows of its cats —
-- those cats are about to stop existing.
delete from follows f
where f.user_id = sqlc.arg(user_id)
   or f.cat_id in (select c.id from cats c where c.created_by_user_id = sqlc.arg(user_id));

-- name: DeleteAccountReports :exec
-- Reports the account filed, plus reports pointing at content this deletion
-- removes. The latter are not "the account's data", but a report whose
-- target no longer exists can never be reviewed and target_id carries no
-- foreign key to clean it up later (see docs/architecture/db.md).
delete from reports r
where r.reporter_user_id = sqlc.arg(user_id)
   or (r.target_type = 'cat' and r.target_id in (
        select c.id from cats c where c.created_by_user_id = sqlc.arg(user_id)))
   or (r.target_type = 'update' and r.target_id in (
        select u.id from updates u
        where u.author_user_id = sqlc.arg(user_id)
           or u.cat_id in (select c.id from cats c where c.created_by_user_id = sqlc.arg(user_id))))
   or (r.target_type = 'media' and r.target_id in (
        select m.id from media m where m.uploaded_by_user_id = sqlc.arg(user_id)));

-- name: DeleteAccountBlocks :exec
-- Both directions: the blocks this account made, and the blocks other
-- accounts made against it (which have nothing left to hide).
delete from user_blocks b
where b.blocker_user_id = sqlc.arg(user_id)
   or b.blocked_user_id = sqlc.arg(user_id);

-- name: ClearCoversReferencingAccountMedia :exec
-- cats.primary_photo_id references media, so every cover pointing at media
-- about to be deleted has to be cleared first. This deliberately reaches
-- beyond the account's own cats: a cat someone else owns can have this
-- account's photo as its cover, and that photo is going away. That cat
-- keeps existing, without a cover, rather than being deleted along with it.
update cats
set primary_photo_id = null
where primary_photo_id in (
  select m.id from media m where m.uploaded_by_user_id = sqlc.arg(user_id)
);

-- name: DeleteAccountCatMedia :exec
delete from cat_media cm
where cm.cat_id in (select c.id from cats c where c.created_by_user_id = sqlc.arg(user_id))
   or cm.media_id in (select m.id from media m where m.uploaded_by_user_id = sqlc.arg(user_id));

-- name: DeleteAccountCats :exec
delete from cats c where c.created_by_user_id = sqlc.arg(user_id);

-- name: DeleteAccountMedia :exec
delete from media m where m.uploaded_by_user_id = sqlc.arg(user_id);

-- name: DetachAccountDevices :exec
-- A device is an installation, not a person: it can go on being used as a
-- guest, and a future account can link it again. So the association and the
-- credential are revoked rather than the row deleted — deleting it would
-- also break the notifications/follows history of whoever uses that phone
-- next, and leave the running app with a device token the server has never
-- heard of.
update devices
set user_id = null, revoked_at = now()
where user_id = sqlc.arg(user_id);

-- name: DeleteAccountRefreshTokens :exec
-- The access token stays valid until it expires (it is a stateless jwt);
-- without a refresh token the session cannot be renewed past that, and the
-- user row it names is gone, so every account-scoped read fails first.
delete from refresh_tokens t where t.user_id = sqlc.arg(user_id);

-- name: DeleteAccountOtpCodes :exec
-- Keyed by phone, not by user: leaving a consumed/pending code behind would
-- follow the number to whoever registers it next.
delete from otp_codes o where o.phone = sqlc.arg(phone);

-- name: DeleteUser :exec
delete from users u where u.id = sqlc.arg(user_id);
