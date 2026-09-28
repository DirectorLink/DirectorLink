-- Which account uses which of the home's API keys (docs/ACCOUNTS.md): learned from the key an
-- invitation made and from each sealed request the home accepted. The controller tells which keys
-- still exist (docs/RELAY.md, "keys"); a member whose keys are all gone leaves the home. Key ids
-- only: the cloud never has keys.

CREATE TABLE member_keys (
  home_id TEXT NOT NULL REFERENCES homes (id) ON DELETE CASCADE,
  key_id TEXT NOT NULL,               -- the controller's API key id (8 hex)
  user_id TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  added_at TEXT NOT NULL,
  PRIMARY KEY (home_id, key_id)
);
CREATE INDEX member_keys_by_member ON member_keys (home_id, user_id);
