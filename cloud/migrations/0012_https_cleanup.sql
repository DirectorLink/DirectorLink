-- Direct HTTPS's housekeeping (1.13.0, ADR-082 as changed then, src/https.js): a name nobody uses
-- any more loses its A record, or goes with its home, every day; and the ACME account's URL is kept
-- for dlhome.cc's CAA record (cloud/README.md).

-- When the home's controller last said, over its connection, that it serves its name (an `https`
-- with its address, or a certificate asked for: written at most once a day), or the daily cleanup
-- found it connected and serving it; when it said off (null while on); when the name's A record was
-- written (null while it has none). The cleanup reads them to find the names to look at.
ALTER TABLE https_names ADD COLUMN seen_at TEXT;
ALTER TABLE https_names ADD COLUMN off_at TEXT;
ALTER TABLE https_names ADD COLUMN dns_at TEXT;

-- The names of 1.12.x: seen now (30 days from this migration), and an A record for each that has
-- had a certificate.
UPDATE https_names SET seen_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), dns_at = issued_at;

-- The ACME account the Worker uses at each directory (ACME_DIRECTORY), as Let's Encrypt gave its URL
-- (registered at the first order, or found with newAccount's onlyReturnExisting). Not a secret: the
-- CAA record names it (accounturi), so that only this account gets certificates for dlhome.cc.
CREATE TABLE acme_accounts (
  directory TEXT PRIMARY KEY,          -- the directory's URL
  url TEXT NOT NULL,                   -- the account's URL, e.g. https://acme-v02.api.letsencrypt.org/acme/acct/123
  key TEXT NOT NULL,                   -- the JWK thumbprint (RFC 7638) of ACME_ACCOUNT_KEY's public key
  found_at TEXT NOT NULL               -- when the Worker learned it (ISO 8601, UTC)
);
