-- Sign-in identities (docs/ACCOUNTS.md): one account may sign in with Google and with Apple. An
-- identity is the provider's own stable id for the person; an account is found only by it (never by
-- email), and a signed-in account may add the other provider. users.provider and users.subject stay:
-- the identity the account began with.

CREATE TABLE identities (
  provider TEXT NOT NULL,             -- 'google' or 'apple'
  subject TEXT NOT NULL,              -- the provider's id for this person ("sub")
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  email TEXT NOT NULL,                -- lowercase, as the provider last gave it
  created_at TEXT NOT NULL,
  last_sign_in_at TEXT NOT NULL,
  PRIMARY KEY (provider, subject)
);
-- One identity per provider for an account.
CREATE UNIQUE INDEX identities_by_user ON identities (user_id, provider);

INSERT INTO identities (provider, subject, user_id, email, created_at, last_sign_in_at)
  SELECT provider, subject, id, email, created_at, last_sign_in_at FROM users;

-- Which provider a sign-in in progress is for (its state only works at that provider's callback),
-- and the signed-in account that asked to add it, if any.
ALTER TABLE sign_ins ADD COLUMN provider TEXT NOT NULL DEFAULT 'google';
ALTER TABLE sign_ins ADD COLUMN link_user_id TEXT;
