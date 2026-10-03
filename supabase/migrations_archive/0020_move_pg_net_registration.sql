-- Flashi 0020: move pg_net's extension registration namespace out of public.
-- At authoring time the project had no external pg_net dependencies and no
-- queued requests. Dropping/recreating is therefore safe for this deployment.
-- Do not reuse this migration blindly on a database with webhooks or callers
-- that depend on pg_net; back up and inventory those dependencies first.

drop extension if exists pg_net;
create extension pg_net with schema extensions;
