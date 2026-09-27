-- Accounts (docs/ACCOUNTS.md): who signed in, their sessions, and sign-ins in progress.
-- Applied with: npx wrangler@4 d1 migrations apply directorlink --remote   (--local for wrangler dev)

-- One row per person, keyed by the sign-in provider's own stable id for them.
CREATE TABLE users (
  id TEXT PRIMARY KEY,                -- random, 32 hex characters
  provider TEXT NOT NULL,             -- 'google'
  subject TEXT NOT NULL,              -- the provider's id for this person ("sub")
  email TEXT NOT NULL,                -- lowercase, verified by the provider
  name TEXT,
  created_at TEXT NOT NULL,           -- ISO 8601, UTC
  last_sign_in_at TEXT NOT NULL,
  UNIQUE (provider, subject)
);

-- The session cookie holds a random token; only its SHA-256 is stored.
CREATE TABLE sessions (
  token_sha256 TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX sessions_by_user ON sessions (user_id);

-- A sign-in while the browser is at the provider (10 minutes). The browser holds the state in a
-- cookie; the PKCE verifier and the nonce never leave the server.
CREATE TABLE sign_ins (
  state_sha256 TEXT PRIMARY KEY,
  nonce TEXT NOT NULL,
  verifier TEXT NOT NULL,
  return_to TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
