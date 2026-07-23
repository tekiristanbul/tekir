-- +goose Up
create extension if not exists postgis;
create extension if not exists pgcrypto;

-- +goose Down
drop extension if exists pgcrypto;
drop extension if exists postgis;
