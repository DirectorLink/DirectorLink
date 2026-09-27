# Accounts and end-to-end encrypted remote access

**Status: proposal, awaiting approval.** Nothing here is built yet. It extends the remote-access
test (`docs/RELAY.md`, version 0) and ADR-027.

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
  `K` goes into Director's encrypted persistence once that is shown to survive updates on a real
  controller; otherwise it goes into plain persistence.
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
  (it remembers ids for 5 minutes), so a captured envelope cannot be replayed.
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
   once; valid for 5 minutes) and gives it to the cloud.
4. The cloud asks the controller, over the relay, whether the token is right. The controller
   confirms and forgets the token; the cloud records the account as the home's owner and renews
   the home's connection secret.

From then on this device also works away from home. A later claim from the home network, which
again needs an admin key there, moves the home to the new account: whoever controls the controller
controls the home (ADR-027).

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
3. The app shows a link and a QR code: `https://app.directorlink.io/join#<home_id>.<invitation id>.<I>`.
   Everything after `#` stays in the browser and is never sent to any server. The admin shares it
   (WhatsApp, email, a QR code on screen). The cloud is told only the invitation id, the email and
   the expiry.
4. The invited person opens the link and signs in. The cloud checks their email against the
   invitation. If the two differ (for example with Apple's *Hide My Email*), it asks the owner to
   approve. Then it passes on the person's first envelope, which is locked with keys derived from
   `I` (`HMAC-SHA256(I, "DirectorLink invite v1")`).
5. The controller checks the invitation (unused, not expired), creates a new API key with the
   invitation's role and returns it inside the locked answer. The invitation is used up.

A link lasts 7 days and works once (*my other device*: 10 minutes). Whoever intercepts a link
still has to sign in as the invited email.

### 4. Removing someone, or a lost phone

An admin revokes that device's key (Settings → Members, or the API console). It stops working at
home and away at once, and the cloud membership goes with it. Signing in to the account alone gives
no access, because the keys live only on the devices.

### 5. The home network without an account

Unchanged: pair with a code and use the LAN API. No cloud is involved.

## Cloud storage

Cloudflare D1 (SQLite), next to the relay's Durable Objects:

- `users`: id, sign-in provider, provider subject, email, name, created.
- `homes`: home id, owner, created, hash of the connection secret.
- `members`: home, user, key id, label, added.
- `invitations`: id, home, email, expiry, state.
- No device data, no keys and no message contents. Only message counters, for rate limits.

After sign-in the cloud sets a `Secure`, `HttpOnly`, `SameSite=Strict` cookie for
`directorlink.io`. The page's scripts cannot read it. It lasts 30 days and can be ended from the
app.

## Relay protocol, version 1

Additions to `docs/RELAY.md`; the version 0 messages stay:

| Direction | Message |
| --- | --- |
| relay → driver | `{"type": "claim", "token": "…"}` |
| driver → relay | `{"type": "claim_result", "ok": true, "home_secret": "…"}` (the new connection secret; the relay keeps only its hash) |
| relay → driver | `{"type": "e2e", "envelope": {…}}` |
| driver → relay | `{"type": "e2e", "envelope": {…}}` |
| relay → driver | `{"type": "join", "invitation": "…", "envelope": {…}}` |

The version 0 test endpoints and the viewer-only rule are removed. Roles come from the device's
key.

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

1. **Driver:** lock keys, envelopes over the relay, claim and invitations, with tests against the
   fake Director. On the real controller, check `C4:Encrypt`, `C4:HMAC` and encrypted persistence
   across updates.
2. **Cloud:** Google and Apple sign-in, sessions, homes, members, invitations and routing. Remove
   the test endpoints.
3. **App:** sign-in, claim, automatic choice between home and remote connection, Invite (link and
   QR), Members, iPhone and iPad.
4. **Docs and release:** a privacy page on directorlink.io, and `RELAY.md` version 1.

Needed before phase 2:
- A Google OAuth client (type: web, for app.directorlink.io).
- For Apple: the Services ID, Team ID, Key ID and `.p8` key, plus domain verification of
  directorlink.io.

## To decide

1. Lock keys are derived from each device's API key; there is no separate secret.
2. AES-256-CBC with HMAC-SHA256, a 2-minute window and one-time request ids.
3. The owner claims the home on the home network, from a computer or an Android phone.
   A later claim from the home network moves the home to a new owner.
4. Everyone else joins by an invitation link or QR code that the admin shares. The secret sits
   after `#`, and the invitation is bound to an email, works once and lasts 7 days (10 minutes for
   *my other device*). The owner approves email mismatches.
5. Google and Apple sign-in at launch, with the session in a secure cookie.
6. The cloud stores only accounts, homes, members and pending invitations.
7. Home-network use without an account stays.
8. The test endpoints and the viewer-only rule go when this ships.
