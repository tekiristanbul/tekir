-- +goose Up
-- issue #58: links an anonymous device to the account it verified into.
-- nullable — most devices are never linked, and 00007 deferred this exact
-- column until the users table existed (see docs/architecture/db.md).
-- setting it is the entire "device-to-account linking" operation: follows,
-- cats, and updates already key off device_id and need no rewrite when a
-- device is linked (see 00010's comment on follows).
alter table devices add column user_id uuid references users(id);

-- +goose Down
alter table devices drop column user_id;
