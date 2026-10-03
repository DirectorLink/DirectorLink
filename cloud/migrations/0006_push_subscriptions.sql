-- Alerts on admins' devices (ADR-047, docs/ACCOUNTS.md): the Web Push subscription each browser made
-- for a home, registered by a signed-in member. The home's Durable Object sends to those of its admins
-- (the controller says which key ids are admin keys) when the home has been offline for 10 minutes
-- or a schedule failed. A subscription is the push service's address for that browser and the keys
-- the alert is encrypted with; it says nothing about the person but which account registered it.

CREATE TABLE push_subscriptions (
  home_id TEXT NOT NULL,
  endpoint TEXT NOT NULL,             -- the push service's https address for this browser
  user_id TEXT NOT NULL,              -- the account that registered it
  p256dh TEXT NOT NULL,               -- the browser's public key (base64url, 65 bytes)
  auth TEXT NOT NULL,                 -- the browser's authentication secret (base64url, 16 bytes)
  created_at TEXT NOT NULL,           -- ISO 8601, UTC
  PRIMARY KEY (home_id, endpoint),
  -- Leaving the home (or the account going) removes it.
  FOREIGN KEY (home_id, user_id) REFERENCES members (home_id, user_id) ON DELETE CASCADE
);
CREATE INDEX push_subscriptions_by_member ON push_subscriptions (home_id, user_id);
