# Accounts and end-to-end encrypted remote access

**Status: approved on 2026-09-27 (ADR-029); built in DirectorLink 0.10.0 with Google. Sign in with
Apple is built in the cloud and the app (`cloud/src/apple.js`), and is switched on in the app once
its keys are set up (cloud/README.md).** The driver's side is `driver/src/cloud/` (`lock.lua`, `remote.lua`) and
`driver/src/auth/invitations.lua`, the cloud's `cloud/src/accounts.js` and `cloud/src/homes.js`, the
app's `app/js/lock.js`, `app/js/remote.js` and Settings → Account. The relay protocol is
`docs/RELAY.md`, version 1. Known issues are listed at the end.

## Goals

- Sign in with Google or Apple and use the home from anywhere, including from iPhones and iPads.
- **The cloud can route, but not read.** Everything between the app and the controller is locked
  with keys that only the app and the controller hold. DirectorLink's servers, and Cloudflare
  beneath them, see that a device talked to a home, when, and how much. They never see what.
- The owner proves control of the home once, on the home network. Everyone else joins by
  invitation, without Composer and without the home network: family, and the owner's own other
  devices.
- Roles stay those of API keys (`viewer`, `member`, `doors`, `admin`), enforced by the controller.
- Using the app on the home network without an account keeps working.

Not part of this design: push notifications, local HTTPS, native apps, billing.

## Who knows what

| | App (your device) | Cloud (`api.directorlink.io`) | Controller |
| --- | --- | --- | --- |
| Account: email, name, sign-in provider | yes | yes | no |
| Which homes the account belongs to | yes | yes | — |
| API key and lock key | its own | **never** | lock keys of the home's devices; API keys only as hashes |
| Devices, rooms, states, commands, pictures | yes | **never** (locked) | yes |
| When, and how much data, flows | yes | yes | yes |

A stolen or hacked cloud database gives an attacker email addresses and which account belongs to
which home. It cannot open a door, read a light's state or show a picture.

## Keys

Every device already has its own API key `S` (`ak_…`), from pairing or from an invitation. The
**lock key** for remote use is derived from it:

```
K     = HMAC-SHA256(S, "DirectorLink e2e v1")
K_enc = HMAC-SHA256(K, "enc")        K_mac = HMAC-SHA256(K, "mac")
```

- The app keeps `S`, as today, and holds `K` as a non-extractable WebCrypto key.
- The controller keeps `S` only as a hash (ADR-028). It therefore stores `K` alongside each key
  when it creates that key, and for older keys the first time they are used on the home network.
  Both are in Director's plain persistence, which survives driver updates (`src/core/store.lua`).
- Revoking an API key revokes its remote access too. There is no second secret to lose, rotate or
  copy between devices.

## The lock

Every remote request and every answer travels as one envelope:

```json
{"v": 1, "home": "<home_id>", "key": "<key id>", "iv": "<base64, 16 bytes>", "ct": "<base64>", "mac": "<base64>"}
```

- `ct` = AES-256-CBC(`K_enc`, `iv`, plaintext); `mac` = HMAC-SHA256(`K_mac`,
  `"v1|" + home + "|" + key + "|" + dir + "|" + iv + "|" + ct`), where `dir` is `req` or `res`.
  The MAC is checked, in constant time, before anything is decrypted (encrypt-then-MAC).
- Request plaintext: `{"id", "ts", "method", "path", "body"}`. Answer plaintext: `{"id", "ts",
  "status", "content_type", "body" | "body_base64"}`. These are the same requests and answers as
  the LAN API.
- The controller accepts a request only within 2 minutes of its own clock, and only once per `id`
  (it remembers ids for 5 minutes), so a captured envelope cannot be replayed. A request sealed
  before the driver started is refused; the ids of requests dated ahead of the controller's clock
  are also saved in persistence until the window has passed, so a restart does not open a replay.
- At every start the driver checks `C4:HMAC` and `C4:Encrypt` against a known vector
  (`tests/vectors/lock.json`, which the app and cloud tests check too). If that fails, remote
  requests, claims and invitations are refused (`LOCK_UNAVAILABLE`) rather than weakened.
- Why not AES-GCM: DriverWorks documents `C4:Encrypt` with AES-256-CBC, and `C4:HMAC`, but no GCM
  tags. CBC with an HMAC over the ciphertext is the standard safe construction, and browsers have
  both in WebCrypto. The driver functions are native, so camera pictures stay fast.
- The cloud sees the home id, the key id, the size and the time of each envelope.

## Flows

### 1. The owner claims the home (once, on the home network)

1. Pair as today, on a computer or an Android phone, with the pairing code from Composer. The
   device gets an admin key `S`.
2. Sign in with Google or Apple in the app.
3. Over the home network, the app asks the controller for a claim token (admin keys only; works
   once; valid for 5 minutes, and only while the key that asked for it is still an admin key) and
   gives it to the cloud.
4. The cloud asks the controller, over the relay, whether the token is right. The controller
   confirms and forgets the token; the cloud records the account as the home's owner.

From then on this device also works away from home. Another device of the same account links with
its own key and skips the claim. A later claim from the home network, which again needs an admin
key there, moves the home to the new account and removes the previous members and invitations:
whoever controls the controller controls the home (ADR-027). The app asks before doing that.

### 2. Away from home

The app tries the controller on the home network first, because that is faster. If the controller
cannot be reached, and always on iPhone and iPad, the app sends locked envelopes to the cloud with
the account's session. The cloud checks that the account is a member of the home and passes the
envelope to the home's relay connection. The controller unlocks it, runs it as that key (with that
key's role), locks the answer and sends it back.

### 3. Invitations: family, and the owner's own other devices

1. An admin taps **Invite**, picks a role and enters the person's email, or chooses *my other
   device*.
2. The admin's app asks the controller, locally or through the lock, for an invitation. The
   controller creates an invitation id and a random secret `I`, and remembers the role and the
   expiry.
3. The app shows a link and a QR code: `https://app.directorlink.io/#/join/<home_id>.<invitation id>.<I>`.
   Everything after `#` stays in the browser and is never sent to any server; the app takes it out
   of the address as the page opens and keeps it for that tab only. The admin shares it (WhatsApp,
   email, a QR code on screen). The cloud is told only the invitation id, the email and the
   expiry, once: an invitation cannot be moved to another email.
4. The invited person opens the link and signs in. The cloud checks their email against the
   invitation and refuses another one (`EMAIL_MISMATCH`). Then it passes on the person's first
   envelope, which is locked with keys derived from `I` (`HMAC-SHA256(I, "DirectorLink invite v1")`).
5. The controller checks the invitation (unused, not expired), creates a new API key with the
   invitation's role and returns it inside the locked answer. The invitation is used up.

A link lasts 7 days and works once (*my other device*: 10 minutes). Whoever intercepts a link
still has to sign in as the invited email. Revoking or demoting an admin's key revokes the
invitations it made, and Composer's **Revoke All API Keys** revokes every invitation and claim token
too. Each account may have 20 invitations waiting per home.

### 4. Removing someone, or a lost phone

An admin revokes that device's key: in the app (Settings → Controller → **People and devices**),
the API console, or Composer's Revoke All API Keys. It stops working at home and away at once.
Signing in to the account alone gives no access, because the keys live only on the devices.

The cloud keeps which account uses which key, by key id only (`member_keys`): the key an
invitation made (the controller's `join_result`), and the key of each sealed request the home
accepted, which only the key's holder can seal. The controller sends its list of key ids when it
connects and after every change (`{"type":"keys"}`, `docs/RELAY.md`); an account whose keys are all
gone leaves the home, except its owner. The owner's **People and devices** screen shows each
account with its devices; removing someone there revokes their keys at home first, then ends the
membership.

### 5. The home network without an account

Unchanged: pair with a code and use the LAN API. No cloud is involved.

## Google and Apple

Both are OpenID Connect sign-ins run by `api.directorlink.io` (`google.js`, `apple.js`, the shared
ID token checks in `jwt.js`); no provider script runs in the app's pages.

- **Accounts are found by identity, never by email.** Each provider identity (provider and its
  `sub`) is kept in `identities`, and a sign-in with an identity nobody has makes a new account,
  even when an account with that email exists. Google vouches for an address other than Gmail or
  Workspace only as of when the Google account was made, and addresses pass to other people
  (reused mailboxes, re-registered domains); joining by email would hand them the account.
- **Adding the other provider:** while signed in, Settings → Account → *Also sign in with Apple*
  (or Google) runs that provider's sign-in with `link=1`. The app's page navigates to
  `api.directorlink.io` on the same site, so the session comes along and the sign-in remembers
  which account asked; from another site it does not, and nothing is linked. An identity that
  already belongs to another account is refused (`taken`), and an account has one identity per
  provider. The adding needs the session it was asked from to be still signed in when the provider
  answers, so signing out meanwhile (a shared computer) cancels it. The account's email stays that
  of the identity it was created with; an invitation may be accepted with it or with the email of
  any of the account's sign-ins. Settings can remove either sign-in again, never the last one.
- **Separate accounts still work together:** an invitation checks the signed-in account's email,
  so a person who signs in with Apple with the same address as their Google account can accept
  one, as a second account.
- **Hide My Email:** Apple may give a relay address instead of the person's own, and keeps giving
  it for DirectorLink. Invitations for the real address are refused there (`EMAIL_MISMATCH`); the
  join page says to sign in with Google, to stop using Sign in with Apple for DirectorLink in the
  Apple ID settings and sign in again choosing Share My Email (Apple asks only on the first
  sign-in), or to ask for an invitation to the hidden address. Adding Apple to a Google account
  avoids it.
- **A returning Apple ID without an email** (Apple may leave it out, e.g. after Hide My Email
  forwarding is turned off) is still found by its `sub`; a new account needs a verified email.
- **Apple's form:** Apple posts its answer (`response_mode=form_post`, the only way it sends the name
  and email scopes) from appleid.apple.com, so the 10-minute sign-in cookie for Apple is
  `SameSite=None`; the state, the nonce and the cookie are checked as for Google, and a state only
  works at the callback of the provider it was made for. The name comes only in that first form and
  is not signed: it is only a display name.
- **Apple's client secret** is a JWT (ES256) the Worker signs for each sign-in with the Sign in with
  Apple key, valid for 5 minutes.

## Cloud storage

Cloudflare D1 (SQLite), next to the relay's Durable Objects:

- `users`: id, the provider and subject it began with, email, name, created (`migrations/0001`).
- `identities`: provider, subject, account, email (`migrations/0003`).
- `sessions`, `sign_ins`: hashes of session tokens; sign-ins in progress.
- `homes`: home id, owner, claimed (`migrations/0002`).
- `members`: home, user, added.
- `member_keys`: home, key id, the account that uses it (`migrations/0004`).
- `invitations`: home, invitation id, email, expiry, created by. A used invitation is removed when
  it is accepted; an expired one a day after its expiry (daily cron). When its email's account, its
  creator or the home's owner goes, a pending invitation keeps only its id until then, so that it
  cannot be registered again for another email.
- No device data, no keys and no message contents. The hash of each home's connection secret is
  in the relay's Durable Object storage.

After sign-in the cloud sets a `Secure`, `HttpOnly`, `SameSite=Strict` cookie for
`api.directorlink.io`. The page's scripts cannot read it. It lasts 30 days and can be ended from the
app. Deleting the account deletes its sessions, memberships, owned homes and invitations.

## Relay protocol, version 1

In `docs/RELAY.md`: `e2e`, `join` and `claim` from the relay, answered with `e2e`, `join_result` and
`claim_result`. Version 0's plain requests are refused (410 `RELAY_REQUESTS_RETIRED`) and its test
endpoints are off in production. Roles come from the device's key.

## What the lock does not protect

- **The app's code.** The app is a web page served from app.directorlink.io. Whoever controls that
  site could ship code that reads keys in the browser. The code is open source and deployed only
  from this repository by CI (`deploy.yml`). A native app would remove this trust, later.
- **The controller's storage.** The lock keys `K` are stored on the controller. Whoever can read
  its storage (root access, possibly a project backup) could act as those devices remotely. They
  could not use the LAN API with them, which needs `S`, stored only as a hash.
- **The home network.** The LAN link stays plain HTTP until local HTTPS exists. Someone on the home
  Wi-Fi could capture an API key during pairing, or later.
- **Metadata:** which account uses which home, when, and how much.

## iPhone and iPad

They cannot use the home-network connection: WebKit blocks it (see the README). With this design
they always go through the cloud, locked, even at home. The owner still has to claim the home once
from a computer or an Android phone; the owner's iPhone then joins as *my other device*.

## Phases

1. **Driver** (0.10.0): lock keys, envelopes over the relay, claim and invitations, with tests
   against the fake Director, and a self-test of `C4:Encrypt` and `C4:HMAC` at every start.
2. **Cloud** (0.10.0): Google sign-in, sessions, homes, members, invitations and routing. Apple
   later.
3. **App** (0.10.0): sign-in, linking the home, automatic choice between home and remote
   connection, Add my other device and Invite (link and QR), iPhone and iPad. A Members screen
   later.
4. **Docs and release** (0.10.0): the privacy page on directorlink.io, and `RELAY.md` version 1.

Sign-in details:
- Google's authorization-code flow with PKCE, run by `api.directorlink.io`; the app only navigates
  to `/auth/google/start` and comes back with `?signin=…`. No Google script runs in the app's pages.
- The browser holds the sign-in's state in a 10-minute `__Host-dl_signin` cookie, so a sign-in
  started elsewhere cannot be completed in this browser; the nonce and the PKCE verifier stay on
  the server. The ID token's signature, issuer, audience, expiry, nonce and verified email are
  checked.
- The session is a random token in the `__Host-dl_session` cookie (`Secure`, `HttpOnly`,
  `SameSite=Strict`, 30 days); D1 keeps only its SHA-256. Sign-out and account deletion are
  accepted only from the app's own origins.

Needed later, for Apple: the Services ID, Team ID, Key ID and `.p8` key, plus domain verification
of directorlink.io.

## Known issues

- An invitation must be accepted with the email it was made for; owner approval of another address
  comes later.
- Sign in with Apple is off in the app until its keys are set up.

## Decisions

1. Lock keys are derived from each device's API key; there is no separate secret.
2. AES-256-CBC with HMAC-SHA256, a 2-minute window and one-time request ids.
3. The owner claims the home on the home network, from a computer or an Android phone.
   A later claim from the home network moves the home to a new owner.
4. Everyone else joins by an invitation link or QR code that the admin shares. The secret sits
   after `#`, and the invitation is bound to an email, works once and lasts 7 days (10 minutes for
   *my other device*). Owner approval of email mismatches comes later.
5. Google sign-in first, with the session in a secure cookie; Apple once the whole flow works.
6. The cloud stores only accounts, homes, members and pending invitations.
7. Home-network use without an account stays.
8. The version 0 relayed requests, the test endpoints and the viewer-only rule are gone.
