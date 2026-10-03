-- Automatic backups (docs/BACKUP.md, ADR-048): each day the controller seals a backup to the
-- backup password's public key and sends it over its relay connection, in chunks. The cloud keeps
-- the ciphertext, its size and when it came, and cannot open it: only the password does, in the
-- app. One a day per home (the newest), the last 7, at most 5 MB in all.

CREATE TABLE backups (
  id TEXT PRIMARY KEY,                -- random, 32 hex characters
  home_id TEXT NOT NULL REFERENCES homes (id) ON DELETE CASCADE,
  key_id TEXT NOT NULL,               -- which backup password it is sealed to (16 hex)
  size INTEGER NOT NULL,              -- characters of the sealed backup's text
  chunks INTEGER NOT NULL,
  complete INTEGER NOT NULL DEFAULT 0, -- 1 once every chunk is in
  created_at TEXT NOT NULL            -- ISO 8601, UTC: when it started, then when it was complete
);
CREATE INDEX backups_by_home ON backups (home_id, complete, created_at);

CREATE TABLE backup_chunks (
  backup_id TEXT NOT NULL REFERENCES backups (id) ON DELETE CASCADE,
  idx INTEGER NOT NULL,
  data TEXT NOT NULL,                 -- at most 65536 characters
  PRIMARY KEY (backup_id, idx)
);
