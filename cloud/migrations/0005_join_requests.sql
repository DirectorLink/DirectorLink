-- Requests to join a home with an invitation made for another email (docs/ACCOUNTS.md, ADR-041):
-- Apple's Hide My Email, or another account of the invited person. The home's owner approves or
-- refuses each one; the invitation itself, its secret and its email stay as they are, and it still
-- works once. A request lasts as long as its invitation.

CREATE TABLE join_requests (
  id TEXT PRIMARY KEY,                -- random, 32 hex characters
  home_id TEXT NOT NULL,
  invitation_id TEXT NOT NULL,        -- the controller's invitation id (8 hex)
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  code TEXT NOT NULL,                 -- 6 digits, shown to the person asking and to the owner
  status TEXT NOT NULL,               -- 'pending', 'approved' or 'refused'
  requested_at TEXT NOT NULL,         -- ISO 8601, UTC
  decided_at TEXT,
  UNIQUE (home_id, invitation_id, user_id),
  FOREIGN KEY (home_id, invitation_id) REFERENCES invitations (home_id, id) ON DELETE CASCADE
);
CREATE INDEX join_requests_by_home ON join_requests (home_id, status);
