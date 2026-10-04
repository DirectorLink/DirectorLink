# Preferences, profiles and the home's settings

**Status: built in DirectorLink 0.12.0.** Scenes (0.13.0, `docs/SCENES.md`) and schedules (0.14.0,
`docs/SCHEDULES.md`) follow the same rules. People's roles and permissions: 1.8.0 (ADR-054, *People:
admins and members* below).

## Where each setting lives

| Whose | Examples | Where | Who changes it |
| --- | --- | --- | --- |
| The home's | room names per language, the room order, rooms hidden from members, scenes, schedules, people's roles and permissions | the controller | admins (members run the scenes an admin chose for them) |
| A person's | language, theme, palette, favorites, hidden rooms | the controller, in their **profile** | that person, from any of their devices |
| This device's | the controller's address, the access key, the browser's notification permission | the browser | this device |

Everything on the controller works without the internet and without DirectorLink's servers,
survives driver updates (`src/core/store.lua`), and travels through the end-to-end lock when used
away from home, and from the app on the home network too (1.0.0). The cloud never sees any of it.

## Profiles

- A profile is a person. **Every API key belongs to one profile** (`profile_id` on the key).
- Pairing with a code, an admin creating a key, and an invitation for someone else each make a new
  profile, named after the key (a key created with `profile_id` joins that person instead, 1.8.0).
  **Add my other device** (an invitation with `for_me`) puts the new key in the inviter's profile,
  so a person's phone starts with their language, theme and favorites.
- An admin can move a key to another profile (`PATCH /v1/api-keys/{id}` `profile_id`, or People and
  devices → Person) — for two devices of one person that were paired separately; since 1.8.0 the key
  then has that person's permissions — and rename a profile (`PATCH /v1/profiles/{id}`). A profile
  goes with its last key.
- Keys from before 0.12.0 get a profile each at the first start; an admin can then merge them.
- `GET /v1/profile` / `PATCH /v1/profile` are the caller's own (any role): `prefs` with `language`
  (`auto` or a tag), `theme` (`auto`, `light`, `dark`), `palette`, `favorites` (`"kind:id"`, in
  order) and `hidden_rooms` (room ids). `null` clears one. `version` goes up with every change; sent
  back, it makes the change conditional (409 `VERSION_CONFLICT` if another device changed it).
  Since 1.8.0 `GET /v1/profile` also has `access`: what the caller may see and do (below).

## People: admins and members (1.8.0, ADR-054)

A person has a role, **admin** or **member**, and every key of theirs has that person's permissions:
all of a person's devices follow one change. Before 1.8.0 each key had a role of its own (`viewer`,
`member`, `doors`, `admin`; ADR-025).

- **Admins** do everything: people and their permissions, keys, invitations, rooms, scenes,
  schedules, settings, History, backups, remote access, the log.
- **Members** have what an admin chose for them in Settings → People and devices, or when inviting
  them (`GET`/`PATCH /v1/profiles/{profileId}/access`):

| Permission | What it gives | A new member |
| --- | --- | --- |
| Rooms | the rooms they see: all, or a list | all |
| Lights, Climate (AC and heating), Fans, Blinds, Music (Sonos), Refrigerators | that kind of device in their rooms; off hides the kind from them (lists, Home, Turn off all) and the controller refuses it. Heaters wired as KNX lights follow Lights | all on |
| Cameras | the cameras in their rooms, and a doorbell's picture | on |
| Doors and gates | opening the doors and gates in their rooms (they see them and their state either way); Door Control must be on in Composer too | off |
| Sees the alarm | the alarm's status; Alarm Status must be On in Composer too | on |
| Scenes they may run | those scenes, run in full: devices they could not control themselves too, doors and gates included (with Door Control on) | none |

- A doorbell in a member's rooms rings for them (with its ring alert) either way; its picture shows
  only with Cameras on.
- Members never edit scenes and never see schedules, History, keys, invitations, profiles, room
  settings, controller settings or backups.
- The controller checks every request. A device, room or scene a member may not see answers `404`
  like one that does not exist; a door or gate they see but may not open, `403 FORBIDDEN`.
- `GET /v1/profiles` gives each person's `access`; `GET /v1/profile` and `GET /v1/api-keys/current`
  give the caller's own (an admin's all true), so that the app shows only what they may use.
- The home's **owner** (the person who last claimed it for an account, else the oldest admin) is
  always an admin: no other admin can demote them, change their permissions or revoke or move their
  devices (`403 OWNER_PROTECTED`). There is always an admin (`409 LAST_ADMIN`).
- From 1.7.0, each person gets the highest role among their keys: `admin` an admin, `doors` and
  `member` a member with every room and kind (doors and gates for `doors` only), `viewer` a member
  with no rooms and cameras only. ADR-054 has the details. Every key keeps a 1.7.0 `role` worked
  out from its person, for 1.7.0 apps and for a downgrade.

## The app

- After connecting, and every minute, the app reads the profile and applies its language, theme and
  palette. The first time a profile is used (version 0), this browser's own choices and favorites
  become the profile's. Changes are saved to the profile a moment later, several together.
- The browser keeps its own copy too, so the app opens in the right language before it reaches the
  controller, and works as before with a driver older than 0.12.0 (no profiles).

## Rooms

- **The order is the home's**, one for everyone: admins set it in Settings → Rooms by dragging a room
  by its handle, with the keyboard, or with the arrows, one `PUT /v1/rooms/order` per move;
  `GET /v1/rooms` answers in that order. Rooms not in the order follow, in Control4's order.
- **Hiding is personal**: anyone unticks a room in Settings → Rooms; it goes into their profile's
  `hidden_rooms` and disappears from their Home and Climate, not anyone else's. Favorites in a
  hidden room still show.
- **Hidden from members is the home's** (1.8.0): an admin marks a room in Settings → Rooms
  (`PATCH /v1/rooms/{roomId}` `{"hidden_from_members": true}`), and it and its devices disappear
  for every member, whatever rooms they were given. Admins still see it, marked
  (`hidden_from_members` in `GET /v1/rooms`). Personal hiding stays as it is, on top, for anyone.

## Favorites of removed devices (1.8.0, ADR-059)

A favorite names a device by id (`"camera:60"`). When a device is removed in Composer (a camera
replaced by another, which Control4 gives a new id), its favorite would ask for a device that is
not there: the app showed an empty tile and asked the controller for its picture (404). Now:

- **The controller decides, never on one read.** Only a project read that worked counts (at the
  start, Refresh Project, or Composer's changes, `src/core/favorites_gone.lua`). A read that failed,
  or one in which Director lists no devices at all (as while it loads a project), changes nothing.
  The first such read in which no device of the project has a favorite's id marks it gone, with
  the time and, when the read before still knew it, the device's name and room. A later read that
  has the device again (one missing for a moment while its driver is replaced) clears the mark.
- **The app shows it as removed.** `GET` and `PATCH /v1/profile` add `gone_favorites`, the
  caller's own favorites that are marked (`entry`, `since`, and `name` for someone who may see
  such a device there). Home shows each as a tile "Removed in Composer", with the name it had and
  **Remove**, instead of an empty tile; the app never asks for its device. The app never decides
  by itself that a favorite is gone: its own lists leave out what the person may not see, and may
  be a minute old.
- **After 7 days the controller drops it** from every profile that has it (each profile's
  `version` goes up, so every device of that person sees it), at a project read or at the
  scheduler's minute look, and logs it. Only once a read in this run of the driver has looked at
  the marks: a mark kept from before a restart may be of a device that came back meanwhile.
- A kind of favorite DirectorLink does not know (one a newer version keeps) is never marked or
  dropped. The marks are kept in the driver's data (`directorlink_favorites_gone`), so a restart
  does not start the 7 days again; they are not in backups (the next project read marks again).
- DirectorLink 1.7.0 does not read the marks: its app shows nothing of them, and Home leaves the
  gone favorites out as before. A favorite dropped by 1.8.0 stays dropped after going back.
