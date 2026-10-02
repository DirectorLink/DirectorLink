# Sonos

DirectorLink 1.5.0 shows the home's Sonos speakers in the app: what each Sonos room plays, play,
pause, next and previous, its volume and mute, and the Sonos favorites. The home has no Sonos
driver in Control4, so DirectorLink talks to the speakers itself, on the home network (ADR-044).

## Setup

1. In Composer, select DirectorLink and set the property **Sonos** to `On`. It ships `Off`: then
   DirectorLink does not look for any Sonos and sends nothing to one.
2. Look at **Sonos Players**: within a few seconds it lists the players found, with their
   addresses, e.g. `3 players: Kitchen (192.168.1.38), Living Room (192.168.1.39), Outside (192.168.1.40)`.
3. If it says `None found`, set **Sonos Address** to one player's IP address (the Sonos app shows
   it under Settings → System → About My System). That player lists the others. This is needed
   when the controller and the speakers are on different networks (VLANs), where the search cannot
   reach them.

No restart is needed for either property. Turning Sonos off stops everything at once.

## Rooms

Each Sonos room shows in the Control4 room with the same name, matched without regard to case or
spaces ("Living Room", "living room" and "LivingRoom" are one name). A room's names in other
languages, set in the app, count too: a Sonos room named "מטבח" shows in the Control4 room
"Kitchen" when its Hebrew name is מטבח.

A Sonos room whose name matches no room (or more than one) shows under **No room** until an admin
picks its room in the app under Settings → Rooms → Sonos rooms. The choice is kept on the controller
(`PUT /v1/music/{id}/room`); "Same name" goes back to matching by name. Hidden rooms and the room
order work as for other devices.

A Sonos room is a room as the Sonos app shows it: a stereo pair, or a home theater with its
surrounds and sub, is one room. A Boost or a Bridge is no room.

## In the app

- **On a room's screen**, a Music card for each Sonos room there: the album art, what plays (title,
  artist and album; for the radio, the station and what it plays now; for Spotify Connect or
  AirPlay, the app), whether it plays, and the other rooms of its group.
- **Members and admins** play and pause, skip to the next or previous track, set the volume and
  mute, and start a Sonos favorite. **Viewers** see what plays and the volume.
- **On Home**, "Music playing" lists each group that plays, with a pause button.
- **Groups** are shown as Sonos has them: play, pause and skip on any room of a group act on the
  whole group (its coordinator). The volume and mute are each room's own. DirectorLink does not
  group or ungroup rooms.
- **Favorites** are the household's Sonos favorites (My Sonos). A radio station starts as it is;
  a playlist, an album or a track replaces the group's queue and plays, as the Sonos app's
  "Play now" does. Some favorites, such as Sonos Radio's shortcuts, can only be started in the
  Sonos app: they are greyed out.
- **Album art** comes through the controller, like camera pictures: the app's page is HTTPS and the
  speaker answers plain HTTP on the home network.

## Scenes

A scene step can pause or stop the music in a room, or in the whole home ("Good night: music off").
A group pauses as one: if the room is grouped with others, they pause too. A radio station, which
Sonos cannot pause, stops. Scheduled scenes run music steps like any other (as a member's key).
With Sonos off, a music step is skipped and says why.

## How DirectorLink talks to the speakers

Sonos speakers answer a local protocol on port 1400: UPnP, with SOAP calls to the services
AVTransport, RenderingControl, ZoneGroupTopology and ContentDirectory. The Sonos app, Home
Assistant and Control4's own Sonos driver use it. **Sonos does not document it**; it has stayed
the same for years, but a Sonos update could change it. (Sonos's documented Control API works
through Sonos's cloud, which DirectorLink does not use.)

- **Finding the players.** An SSDP search (UDP to 239.255.255.250:1900, for
  `urn:schemas-upnp-org:device:ZonePlayer:1`) when Sonos is turned on and every 5 minutes, and the
  player at Sonos Address if set. One player's zone group state (GetZoneGroupState) lists every
  room and group with its address.
- **Only the players.** DirectorLink sends requests only to addresses of the home network
  (10.x, 172.16–31.x, 192.168.x) on port 1400, which a player gave in its answer to the search or
  in its zone group state, or which the installer typed in Composer. An API request names a Sonos
  room, never an address. No other host is contacted: album art a music service keeps on its own
  servers is not shown. `scripts/check_package.py` fails the build if any other part of the driver
  talks to the players, or if another action is added.
- **What it sends.** Reading: GetTransportInfo, GetPositionInfo, GetMediaInfo, GetVolume, GetMute,
  GetZoneGroupState, Browse of the favorites (FV:2), and a GET of the album art. Controlling: Play,
  Pause, Stop, Next, Previous, SetVolume, SetMute, and to start a favorite SetAVTransportURI,
  RemoveAllTracksFromQueue and AddURIToQueue. Nothing else: no grouping, alarms or settings.
- **How often.** A room someone has open in the app (its room screen, or Home for all of them) is
  read every few seconds for 15 seconds after each look; the app looks every 5 seconds. The others
  are read once a minute, and the groups every 30 seconds while someone looks, else every 5 minutes.
  A read is one request at a time per group (its transport and track on the coordinator, then each
  room's volume and mute); at most 4 requests are on their way at once, each with a 4-second
  timeout, so the controller's single Lua thread never waits for a speaker. After a command the
  room is read again within 2 seconds.

## API

`GET /v1/music` (every Sonos room, or `?room_id=` those shown in a room), `GET /v1/music/{id}`,
`POST /v1/music/{id}/play|pause|next|previous`, `PATCH /v1/music/{id}` (`volume`, `muted`),
`GET /v1/music/{id}/favorites`, `POST /v1/music/{id}/favorites/{favoriteId}/play`,
`GET /v1/music/{id}/art`, and for admins `PUT /v1/music/{id}/room`. Viewers read; members and
admins control. See [`api/README.md`](../api/README.md) and `api/openapi.yaml`.

## Limits

- The protocol is not documented by Sonos (above).
- Spotify Connect and AirPlay play through the speaker from another app: DirectorLink shows the
  app's name, and the track only when the speaker reports it. Next and previous are passed on to
  that app.
- Volume and mute are per room; there is no group volume.
- Album art only from the speaker itself (most music services' art comes through it).
- Starting a playlist, album or track favorite replaces the group's queue.
- The Sonos room choices are not in DirectorLink backups yet: after a restore, an admin picks them
  again.
- Read against the owner's players (three Sonos Amps, software 97.1, S2): their answers, anonymised,
  are the test fixtures in `tests/sonos/real/`. Grouped rooms, a stereo pair, a home theater, a
  track from the queue, the radio and playable favorites were made in the same shapes
  (`tests/sonos/made/`). Older S1 players have not been tried.
- The search from a DriverWorks driver (a UDP network connection, as Snap One's own SSDP module
  does it) has not been seen on a real controller yet; Sonos Address is the way when it finds
  nothing.

## Testing without speakers

- The driver's tests use fake players (`driver/tests/sonos_fake.lua`) answering with the fixtures.
- `node tests/sonos/fake-sonos.mjs --port 8212` runs fake players (Kitchen leads Living Room and
  plays a track, Bedroom plays the radio, TV Room is paused in Spotify Connect), and
  `python scripts/dev_server.py --sonos 8212` runs the driver against them; the contract test
  (`scripts/check_contract.py`) does the same on a free port.
