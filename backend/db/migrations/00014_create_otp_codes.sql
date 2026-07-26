-- +goose Up
-- issue #58: one-time verification codes for phone-based login. only the
-- sha-256 hash of the code (bound to its phone number) is stored, never
-- the plaintext — matching the devices.token_hash/refresh_tokens.token_hash
-- convention, so a leaked otp_codes row is not itself usable to log in.
-- attempts/max_attempts enforce a brute-force limit per issued code;
-- consumed_at prevents an already-used code from ever verifying again
-- (replay prevention). phone is stored normalized (e.g. +90XXXXXXXXXX),
-- matching users.phone. expiry and attempt-limit decisions are made by the
-- service layer against its own injected clock, never this table's own
-- now(), so behavior stays deterministically testable.
create table otp_codes (
  id           uuid primary key default gen_random_uuid(),
  phone        text not null,
  code_hash    text not null,
  attempts     int not null default 0,
  max_attempts int not null default 5,
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index otp_codes_phone_created_idx on otp_codes (phone, created_at desc);

-- +goose Down
drop table otp_codes;
