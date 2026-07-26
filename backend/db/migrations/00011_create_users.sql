-- +goose Up
-- issue #58: authenticated accounts. phone is the account identity — the
-- unique constraint is what makes otp verification resolve-or-create
-- exactly one account per normalized phone number, even under two
-- concurrent verify requests for the same number (the losing insert hits
-- this constraint and the caller falls back to a lookup).
create table users (
  id                uuid primary key default gen_random_uuid(),
  phone             text unique not null,
  phone_verified_at timestamptz not null,
  created_at        timestamptz not null default now()
);

-- +goose Down
drop table users;
