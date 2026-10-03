-- Flashi schema snapshot 00: extensions.
-- All optional extensions are centralized before any dependent object.
create extension if not exists "uuid-ossp" with schema extensions;
create extension if not exists "pgcrypto" with schema extensions;
create extension if not exists "vector" with schema extensions;
create extension if not exists "pg_net" with schema extensions;
create extension if not exists "pg_cron" with schema extensions;
