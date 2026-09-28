-- Homes claimed by an account, who belongs to them, and invitations waiting to be accepted
-- (docs/ACCOUNTS.md). No device data and no keys: the cloud only routes sealed messages.

CREATE TABLE homes (
  id TEXT PRIMARY KEY,                -- the home_id the controller connects with (32 hex)
  owner_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  claimed_at TEXT NOT NULL
);

CREATE TABLE members (
  home_id TEXT NOT NULL REFERENCES homes (id) ON DELETE CASCADE,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  added_at TEXT NOT NULL,
  PRIMARY KEY (home_id, user_id)
);
CREATE INDEX members_by_user ON members (user_id);

-- An invitation the controller created; the cloud knows only its id, for whom and until when.
CREATE TABLE invitations (
  home_id TEXT NOT NULL REFERENCES homes (id) ON DELETE CASCADE,
  id TEXT NOT NULL,                   -- the controller's invitation id (8 hex)
  email TEXT NOT NULL,                -- lowercase: the account that may accept it
  expires_at TEXT NOT NULL,
  created_by TEXT NOT NULL,
  accepted_by TEXT,
  accepted_at TEXT,
  PRIMARY KEY (home_id, id)
);
