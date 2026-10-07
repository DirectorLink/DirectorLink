# Schedules and the weather

**Status: built in DirectorLink 0.14.0; Shabbat and holidays in 1.2.0; the weather from a saved
forecast in 1.10.0 (ADR-071).**

A schedule runs a [scene](SCENES.md) by itself: at a time of day, at sunrise or sunset, when the
weather turns, or when Shabbat and holidays begin or end. The controller keeps and runs them
(`src/core/schedules.lua`, `src/core/scheduler.lua`), in its own local time, whether or not any app
is open, and they survive driver updates. They are DirectorLink's own: Composer's scheduler is never
read or changed.

## Who does what

| Role (1.8.0, ADR-054) | Schedules |
| --- | --- |
| member | sees the weather, never the schedules (`403 FORBIDDEN`) |
| admin | sees, makes, changes, switches off and deletes them |

Up to 1.7.0 every role saw the schedules and only `admin` changed them (ADR-025).

A scheduled scene runs as DirectorLink itself: every device in it, but doors and gates are always
skipped, as in 1.7.0. Opening a door or gate needs a person.

## A schedule

- `scene_id`: the scene to run. A scene that schedules run cannot be deleted (409
  `SCENE_IN_USE`).
- `days`: weekdays, 0 (Sunday) to 6 (Saturday), at least one.
- `enabled`: `false` switches it off.
- `trigger`, one of:
  - **time**: `{"type": "time", "at": "06:45"}`.
  - **sun**: `{"type": "sun", "event": "sunrise"|"sunset", "offset": -30}` — minutes before
    (negative) or after, up to three hours. Sunrise and sunset are worked out on the controller
    for the project's location, so they need no internet.
  - **weather**: `{"type": "weather", "kind": "heat"|"wind"|"rain", "above": 30, "from":
    "12:00", "to": "20:00", "once_a_day": true}`:
    - heat: hotter than `above` °C (15–45), which means `above` or more, as it always has (23.0°
      is hotter than 23°); it runs again only after it has cooled 2° below;
    - wind: stronger than `above` km/h (10–150); again only after it has dropped 10 km/h below;
    - rain: when it starts to rain; again only after an hour without rain (in the forecast, like
      everything about the weather: [The weather](#the-weather));
    - `from`/`to` (optional) limit it to those hours (they may cross midnight); `once_a_day`
      (default on) at most once per day. With hours, the rule is ready again each day when its
      hours begin (1.10.0), whatever the weather did overnight: "08:00 to 23:00, hotter than 23°"
      runs every day from 08:00 once it is that hot, even after a night that never cooled 2° below.
  - **shabbat** (1.2.0, with the Jewish calendar on): `{"type": "shabbat", "event":
    "candle_lighting"|"havdalah", "offset": -30}` — when Shabbat or a holiday begins or ends, plus
    minutes before (negative) or after, up to six hours (see [Shabbat and holidays](#shabbat-and-holidays)).
- `only_if` (time, sun and Shabbat schedules): `not_raining`, `hotter_than` (°C; more than it, unlike
  a heat rule's `above`), `wind_below` (km/h),
  `rain_expected` (today's forecast: a 50% chance or more). They are checked when the schedule is
  due, with the weather then (the forecast's).
- `if_no_weather`: what a schedule with `only_if` does when there is no weather data (no forecast
  read yet, or the saved one ran out after 5 days without the internet; no location): `run` (the
  default) or `skip`.
- `during_shabbat` (1.2.0; time, sun and weather schedules): `run` (the default: as on any day),
  `skip` (not on Shabbat and holidays) or `only` (only then).
- Read back with `next_run` (time, sun and Shabbat) and `last_run` (`ran`, `skipped`, `failed`, and
  `note`: `no_weather`, `late`; or `skipped_by`: `only_if`, `no_weather`, `shabbat`), and, for a
  schedule that uses the calendar, `calendar_status` (`ok`, `off`, `no_location`; otherwise `null`).
- At most 50. `version` works as for scenes (409 `VERSION_CONFLICT`).

## Running

- Every minute the controller checks the schedules. A time or sun schedule runs at its minute —
  up to 5 minutes late after a restart, also across midnight — and once; a schedule changed after
  its time starts with the next one. On the day clocks go forward, a time in the skipped hour runs
  when it would have (e.g. 02:30 at 03:30). Shabbat schedules, and those only on Shabbat and
  holidays, are caught up for 6 hours after a restart (below).
- Switching a schedule off and on, or changing it, does not make it run again the same day.
- Weather schedules run when the reading crosses the threshold (or rain starts), on their days,
  within their hours; hours across midnight (22:00–06:00) belong to the day they start. Since
  1.10.0 they run after the time, sun and Shabbat schedules of the same minute (also those caught
  up after a restart): a morning scene at 08:30 does not undo what "hotter than 23°, from 08:30"
  just did.
- What the scheduler remembers (last run, whether a weather schedule may run again) is saved, so a
  restart does not run anything twice. A save that fails is logged; if what it remembers cannot be
  read at a start, nothing is caught up then (below), and the log says so.
- Each run is logged (`GET /v1/logs?category=schedules`), since 1.10.0 with `forecast_from`: when
  the forecast that decided it was read, for a run the weather decided.

## The weather

- From **Open-Meteo** (open-meteo.com, free, no account): since 1.10.0 (ADR-071) its **hourly
  forecast** for the next 5 days (temperature, precipitation, wind and weather code) and each day's
  high, low and chance of rain. Weather data by Open-Meteo.com, CC BY 4.0.
- **The weather is always the forecast.** Weather schedules, "only if", `GET /v1/weather` and the
  app all read the saved forecast's hour for now: the temperature and the wind between the two hours
  around now (20° at 08:00 and 26° at 09:00 make 23° at 08:30), and rain when the forecast has any
  precipitation in the hour now (Open-Meteo gives each hour's sum at its end); the weather code
  is the one at the start of the hour now. The hour without rain that a rain rule waits for is the
  forecast's too.
- **Every 6 hours** the **controller** asks `api.open-meteo.com` itself for a new forecast, while an
  enabled schedule needs the weather, and for an hour after an app shows it: 4 requests a day. It
  replaces the saved one. Nothing goes through DirectorLink's servers. It sends the project's
  location rounded to two decimals (about a kilometre), as before.
- **Without the internet** nothing changes for 5 days: the saved forecast (kept across restarts,
  about 3 KB) is used until 5 days after it was read. A failed read is tried again every 30 minutes
  (and logged once); once one succeeds, its forecast is used at once. After 5 days without a new
  one there is no weather (`unreachable`): weather rules wait, and "only if" does what
  `if_no_weather` says. At a start, a saved forecast older than 6 hours is read anew.
- **Why a forecast:** a fraction of the requests (4 a day instead of 96), and the same weather with
  or without the internet, which matters on Shabbat, when nobody fixes anything: "hotter than 23°,
  08:30–23:00, only on Shabbat and holidays" still turns the AC on when the internet fails on
  Friday. The trade-off: a forecast can differ from what happens, usually by a degree or two, and
  the timing of rain more (a shower may come an hour early or late, or not at all).
- The location is the project's latitude and longitude in Composer (project properties). Without
  them, `GET /v1/weather` says `no_location` and weather schedules do not run. A forecast read for
  another location is not used.
- `GET /v1/weather` says `source: "forecast"`, `fetched_at` (when it was read), `forecast_for` (the
  moment `current` is for), `forecast_until` (when it runs out) and, while reads fail, `detail` (why).
  A 1.9.0 driver's answer has no `source`: its weather was measured, every 15 minutes, and counted
  as none after 45 minutes.
- Open-Meteo's free service is for non-commercial use, which a household's own schedules are. An
  installer offering this commercially should check Open-Meteo's terms (they have paid plans).
- `GET /v1/weather` also gives today's sunrise and sunset. Its `location` is given to admin keys
  only, rounded to two decimals; other roles get `null` (1.0.0).

## Shabbat and holidays

**Status: built in DirectorLink 1.2.0 (ADR-037).** It needs the Composer property **Jewish
Calendar** set to On; it ships Off, and then the driver works nothing out and the app shows none of
it.

- **Where the times come from.** The controller works them out itself from the project's latitude
  and longitude (Composer project properties); nothing goes to the network. Candle lighting is
  sunset (to the minute) less 20 minutes and havdalah sunset (to the nearest minute) plus 42, as
  Hebcal prints them; admins change the minutes (0–90 before, 20–90 after) and Israel (one day of
  Yom Tov) or abroad (two) in the app (`PATCH /v1/calendar/settings`, `api/README.md`). Israel or
  abroad is automatic by default: from the location, or else the project's country or time zone.
  Check the times against your community's calendar. The algorithms are in `docs/CALENDAR.md`.
- **One period per run of holy days.** Shabbat and holy days (Yom Tov) that follow each other are
  one period, from the candle lighting before the first day to the havdalah after the last: Rosh
  Hashana on Thursday and Friday with Shabbat is one period of three days. A Shabbat schedule runs
  once when a period begins (`candle_lighting`) or once when it ends (`havdalah`); the candles of
  its later evenings are not a trigger.
- **Moments, not minutes.** Each moment is worked out as a point in time, so an offset may cross
  midnight (havdalah plus 300 minutes runs after midnight, on the next day) and a clock change
  never moves or repeats one (Israel's clocks go forward on a Friday). `days` filter by the local
  weekday of the moment it runs; the app sends all seven.
- **The condition.** Holy time is from candle lighting to havdalah: the start counts, the end does
  not. A time or sun schedule is judged at its minute (one due at 17:59 but checked at 18:01 is
  judged at 17:59); a weather rule when the reading comes. A weather rule held back on Shabbat
  stays armed, and runs after havdalah if the weather still passes. `skip` leaves
  `last_run.skipped_by: "shabbat"`; `only` outside holy time leaves nothing, like a day not in its
  days.
- **Never twice.** A Shabbat schedule runs once a period, whatever changes: an edit (another
  offset), switching it off and on, other minutes, or a restart. Time and sun schedules keep their
  once a day.
- **After a restart.** In the first minute after the driver starts, Shabbat schedules and those
  only on Shabbat and holidays whose moment passed in the last 6 hours, and did not run, run late:
  oldest first, each once, with `last_run.note: "late"`, "late after a restart" in Last Automation,
  and a log line. A family keeping Shabbat cannot make up for them by hand. Everything else keeps
  its 5 minutes. What was due while the schedules were paused, or while the calendar was off or had
  no location, is never caught up, not even by a later restart: the controller keeps the moment
  they could run again (`catch_up_after`, with what the schedules ran). Nor is anything caught up
  when what the schedules ran could not be read at the start: it could run a Shabbat schedule a
  second time.
- **Calendar off, or no location.** No moment counts as holy: Shabbat schedules and `only`
  schedules are kept but do not run (`calendar_status` says `off` or `no_location`, and so does
  Schedule Status), and `skip` schedules run as usual. While the calendar is off, setting a Shabbat
  trigger or `during_shabbat` other than `run` is 409 `JEWISH_CALENDAR_OFF`; switching a schedule
  off or on, its days, its scene, `during_shabbat: "run"` and deleting still work. Turned on again,
  or given a location, they run from their next moment, and nothing is caught up, not even by a
  restart (a moment in the last 5 minutes still runs, as after a pause). Without a location there
  are still the Hebrew date and the weekly reading, but no times.
- **Where the sun does not set** (above about 66°, around midsummer and midwinter) a period whose
  candle lighting or havdalah does not happen has no Shabbat schedules: neither its begin nor its
  end runs, even when the other one happens (a begin whose end never comes would keep the home in
  Shabbat mode until the sun sets again, weeks later), and they wait for the first period that has
  both times again. The condition takes its civil days, from 00:00 on the first day to 24:00 on the
  last, and also from its candle lighting, or to its havdalah, when that one happens.

For example:

```json
{ "trigger": { "type": "shabbat", "event": "candle_lighting", "offset": -30 }, "days": [0, 1, 2, 3, 4, 5, 6] }
{ "trigger": { "type": "shabbat", "event": "havdalah", "offset": 0 }, "days": [0, 1, 2, 3, 4, 5, 6] }
{ "trigger": { "type": "time", "at": "06:30" }, "days": [0, 1, 2, 3, 4, 5, 6], "during_shabbat": "skip" }
{ "trigger": { "type": "time", "at": "08:00" }, "days": [0, 1, 2, 3, 4, 5, 6], "during_shabbat": "only" }
```

Shabbat lights half an hour before candle lighting, the blinds at havdalah, the boiler every
morning but not on Shabbat and holidays, and the living-room air conditioning on Shabbat and
holiday mornings only (each with its `scene_id`).

## For installers (Composer)

Automation that nobody can see is the hardest thing to troubleshoot, so DirectorLink shows its own
in Composer, on the DirectorLink device (0.15.0):

- **Schedules** (On / Paused): pauses every DirectorLink schedule at once, without deleting
  anything — e.g. while troubleshooting. Nothing runs, and nothing is caught up afterwards (except a
  time due in the last 5 minutes), not even by a restart. The app says the schedules are paused by
  the installer.
- **Schedule Status** (read-only): e.g. `3 on · next tomorrow 06:45 Good morning · 1 weather rule ·
  weather forecast from today 08:00`, or `Paused in Composer - 3 schedules are not running`, or
  `None`. When schedules use the weather it ends with the forecast's time, or `no weather forecast
  yet`, `no weather forecast (Open-Meteo unreachable)` (none holds now) or `(no location)` (1.10.0).
- **Last Automation** (read-only): the last scene DirectorLink ran, when, why and what happened,
  e.g. `28 Sep 13:10 Cool the house · heat rule, 31C forecast · 22 devices` (`31C outside` before
  1.10.0), or
  `28 Sep 22:25 Good night · run from Dana's iPhone · 24 devices`. Kept across driver updates.
- **Print Schedules and Scenes** (action): prints every schedule (when, the scene, conditions, next
  and last run) and every scene with its steps and device names and ids to the Lua output.
- **Jewish Calendar** (Off / On, 1.2.0): Shabbat and holiday times for schedules and the app. Off by
  default; no restart is needed either way.
- **Calendar Status** (read-only): what the calendar works out, e.g. `Israel (from the location) ·
  candles 20 min before sunset, havdalah 42 min after · next Fri 02 Oct 18:04 to Sat 03 Oct 19:05
  Shabbat, Shmini Atzeret, Simchat Torah`, during a period `Now Shabbat, Shmini Atzeret, Simchat
  Torah until Sat 03 Oct 19:05 · Israel · candles 20, havdalah 42`, `No location - set latitude and
  longitude in the project properties`, or `Off`. Where the sun does not set: `next Fri 19 Jun: no
  sunset at this latitude, no times`.
- With Shabbat schedules, Schedule Status adds `· 2 Shabbat schedules` (Shabbat triggers and those
  only on Shabbat and holidays), or `· 2 Shabbat schedules not running (Jewish Calendar is Off)` /
  `(no location)`. Last Automation says `02 Oct 17:34 Shabbat lights · schedule 30 min before candle
  lighting · 12 devices`, and `, late after a restart` when it ran late. The printout's second line
  is `Jewish calendar: ` and Calendar Status; its schedules read `30 min before candle lighting`,
  `Sat: at havdalah`, and `not on Shabbat and holidays` or `only on Shabbat and holidays`.

Scenes and schedules are DirectorLink's own: they are not in Composer programming, and DirectorLink
does not read that programming. A Composer schedule and a DirectorLink schedule acting on the same
device will both run; these properties are how to find the DirectorLink side.

## The app

- **Scenes → Schedules**: the weather at home (with the Open-Meteo credit; since 1.10.0 "Forecast
  for 14:20, updated today 08:00") and every schedule in a sentence — "Sun–Thu at 06:45 · Runs
  Good morning · Only if it isn’t raining · Next: tomorrow 06:45" — with an on/off switch for
  admins.
- The editor: 1 · the scene; 2 · when — At a time, Sun (sunrise or sunset, an hour or half an
  hour before or after), or Weather (heat, rain, wind, with the reading now, the threshold, the
  hours and at most once a day); 3 · the days (with Every day, Sun–Thu and Fri–Sat); 4 · only if;
  then the whole schedule in one sentence, and Save.
- With the Jewish calendar on (1.2.0, `features.jewish_calendar` in `GET /v1/system`): a fourth
  "when", Shabbat and holidays (candle lighting or havdalah, and how long before or after; no days
  to pick), a row "On Shabbat and holidays: Run as usual / Not on Shabbat and holidays / Only on
  Shabbat and holidays" for the others, the next candle lighting and havdalah under the weather,
  today's Hebrew date and the week's reading on Home, and for admins the minutes and Israel or
  abroad in Settings. With it off none of this shows; a Shabbat schedule says it is not running and
  can still be switched off or deleted.
