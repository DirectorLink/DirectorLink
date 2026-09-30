# Backup and restore

**Status: built in DirectorLink 1.4.0 (ADR-042).**

Updating the driver keeps everything DirectorLink knows. Removing the driver from the project (by
accident), replacing the controller or rebuilding the project loses it all: Control4 deletes a
removed driver's data. A backup brings it back. Admins make one in the app (Settings → Controller →
Backup) and restore it there; the file is locked with a password in the browser, and the controller
never sees the password or the file.

## What a backup holds

| Kept by the driver | In a backup | When restored |
| --- | --- | --- |
| Keys (`directorlink_api_key_hashes`) | Each key as stored: its hash and lock key, name, role, profile, when it was made and when it expires. Never a key itself. | As they were, so every device keeps working without pairing again. Keys whose expiry has passed stay out. The restoring admin's own key stays as it is now (below). |
| Profiles | Each person's language, theme, palette, favorites and hidden rooms. | As they were, favorites and hidden rooms matched to the project. |
| Room names, the room order | Every room's names in every language, and the home's order. | Matched to the project. |
| Scenes | Every scene with its steps, ids and versions. | Steps matched to the project. |
| Schedules | Every schedule's definition. Not what it ran. | They start as if saved at the restore (below). A schedule whose scene is not in the backup stays out. |
| The calendar's settings | Candle lighting and havdalah minutes, Israel or abroad. | As they were. |
| The remote identity | The home id, its secret and the replacements waiting for the owner's approval. | By the rules below. |

Not in a backup: pending invitations (revoked by a restore; see ADR-042 for why), what the schedules
ran, the request ids kept against replays, the random pool, the weather, the last automation shown
in Composer, the pairing and start counters, the log and a claim token (both only in memory).

**Composer properties** are listed, never restored: Door Control, Relay Hold, Schedules, Jewish
Calendar, Alarm Status, Remote Access and Log Level. The restore screen shows how each was set when
the backup was made and how it is now, so the installer can set them again in Composer. A file must
never switch a safety setting on.

## The file

`DirectorLink backup <home> <date>.dlbackup`, made by the app (`app/js/backup.js`):

```json
{"format": "directorlink-backup-file", "version": 1, "header": "{...}", "data": "<base64>"}
```

- `header` is a JSON text: `cipher` (`AES-256-GCM`), `kdf` (`PBKDF2-SHA-256`), `iterations`
  (600000), `salt` (16 random bytes), `iv` (12 random bytes), and the home's name, when the backup
  was made and by which DirectorLink, so the restore screen can say whose backup it is before the
  password is typed.
- `data` is the document (below) as JSON, encrypted with AES-256-GCM under the key PBKDF2-SHA-256
  makes from the password and the salt, with the header's exact text as additional data: a file
  whose header or data was changed does not open. WebCrypto does all of it.
- The password is typed twice, at least 10 characters, with a short strength hint. Without it the
  file cannot be opened, by anyone, DirectorLink included.
- The password and the opened document go nowhere but the sealed requests to this controller.

## The document

`GET /v1/backup` (admins, sealed requests only) answers:

```json
{
  "format": "directorlink-backup",
  "format_version": 1,
  "driver_version": "1.4.0",
  "created_at": "2026-10-01T09:30:00Z",
  "home": { "name": "Home" },
  "composer": { "Door Control": "Enabled", "Relay Hold": "Not allowed", "...": "..." },
  "references": {
    "rooms": { "10": { "name": "Kitchen" } },
    "devices": { "20": { "name": "Kitchen Island", "kind": "light", "room_id": 10 } }
  },
  "sections": {
    "keys": { "version": 4, "keys": [] },
    "profiles": { "version": 1, "profiles": [] },
    "room_names": { "version": 1, "rooms": {} },
    "room_order": { "version": 1, "order": [] },
    "scenes": { "version": 1, "scenes": [] },
    "schedules": { "version": 1, "schedules": [] },
    "calendar": { "version": 1, "settings": {} },
    "remote_identity": { "version": 1, "home_id": "…", "home_secret": "…" }
  }
}
```

Each section is its store as the driver keeps it, with the store's version. `references` names the
rooms and devices the sections refer to by id, as the project named them when the backup was made.
The home's name is its site in Composer's project tree.

It holds every key's lock key and the home secret: whoever has the document can reach the home
through the account, sealed, as any of its devices. That is why it goes only in sealed requests
(`403 SEALED_REQUEST_REQUIRED` otherwise, like `GET /v1/alarm`) and is saved only encrypted.

## Restoring

1. The app opens the file with its password.
2. It sends the document back in parts (`POST /v1/restore/parts`), each small enough for a sealed
   request at home (64 KiB of HTTP body) and through the account.
3. `POST /v1/restore {"upload": …}` checks it: nothing changes, and the answer says what a restore
   would do (`dry_run` is true unless it is false).
4. The app shows it: the date and DirectorLink version, how many of each there are, what was found
   by name, what matches nothing (and where it was used), the Composer settings. **Replace
   everything**, confirmed, sends `{"upload": …, "dry_run": false}`.
5. The result says what was done; the app reads everything again.

The controller checks the whole document first: that it is a DirectorLink backup, that it has every
section in the right shape, and that neither DirectorLink nor a store's version is newer than this
one (`409 BACKUP_TOO_NEW`: update DirectorLink first). Older backups are read as an update reads
their stores (a key store before version 4: the console's keys expire in a day). Then it writes
every store, or none: when one cannot be saved, the ones written so far get their values from
before, and the answer is `500 RESTORE_FAILED` (the upload stays, to try again).

### The restoring admin's key

The key that sends the restore keeps working, as it is now: with the role it has now, added if the
backup does not have it, and its profile with it. If the backup has another key with the same id
(8 random hex digits), that one stays out. If the backup already has 20 keys, the restoring one
comes on top: new devices can pair once some are removed.

### Rooms and devices

Scene steps, favorites, hidden rooms, room names and the room order refer to Control4 ids. For each:

1. The same id, still a room, or a device of the same kind (a lights step needs a light): kept.
   When its name changed, the preview says so (`renamed`).
2. Otherwise the one room of the same name, or the one device of the same kind and name in the
   same room: its new id (`by_name`).
3. Otherwise it is left out and listed (`unmatched`), with the scenes and people's favorites that
   used it. A step with no device left, or whose room matches nothing, is left out: a step without
   its room would act on every room of the home. A step's room that is only where its devices were
   picked is dropped quietly when it is gone; the step keeps its devices.

### Schedules

What the schedules ran stays with the controller that ran them. After a restore every schedule starts
as if saved then: nothing that was due before runs, and nothing is caught up; a weather rule waits
until the weather has turned (it was probably run already where the backup was made).

### Remote access

- The backup's home is the controller's: the identity in use stays (its secret may be newer than
  the backup's). The relay connection stays, and learns the restored key ids: people whose keys are
  not in the backup leave the home in the account.
- Another home (the controller was linked again after the accident): the backup's identity is used,
  and the one in use now is kept as `previous`. Two seconds after the answer (which goes out on the
  connection there is), the controller connects with the backup's identity. The home in the account
  comes back with its people, whose keys the backup has; the home the controller used until then
  goes offline in the account. If the relay refuses the backup's identity (its secret was replaced
  after the backup was made; it tries the waiting replacements first), the controller's own comes
  back, it connects with that, and the log and Remote Status say so. With Remote Access off, this
  happens when it is turned on.
- A device linked to the other home through the account: the app points it at the backup's home.
- Pending invitations and a claim token made before the restore are revoked.

## Limits

- A backup is at most 2 MiB of JSON (a home at DirectorLink's limits: 50 scenes of 40 steps with 100
  devices each, 50 schedules, 100 profiles), in at most 100 parts of 48 KiB. A big home (111 lights,
  50 scenes of 15 steps, 50 schedules, 20 keys, 40 rooms named) is about 130 KB, and the driver
  makes it or restores it in some 0.1 s on a PC (the CORE-1 is about ten times slower).
- One upload at a time, for the key that sent it, kept 10 minutes after its last use.
- Through the account the backup goes as one relay message: download it at home if the account
  refuses it.
- A device that opened the app while the controller's data was gone was told its key is unknown and
  forgot it: that device pairs again. Restore before the family opens the app.
- The restore needs the project read (`503 PROJECT_NOT_READY` until DirectorLink has read it).

## Tests

`driver/tests/test_backup.lua` (round trip into fresh storage, the checks, all or nothing, the
restoring admin's key, matching, schedules, invitations, uploads, the remote identity, a big home),
`tests/app/backup.test.mjs` (the file, the parts, the Settings panel), the contract test
(`scripts/check_contract.py`), and a browser check against the dev server: download, start it again
with fresh storage, pair, restore.
