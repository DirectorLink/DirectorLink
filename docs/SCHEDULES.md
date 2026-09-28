# Schedules and the weather

**Status: built in DirectorLink 0.14.0.**

A schedule runs a [scene](SCENES.md) by itself: at a time of day, at sunrise or sunset, or when
the weather turns. The controller keeps and runs them (`src/core/schedules.lua`,
`src/core/scheduler.lua`), in its own local time, whether or not any app is open, and they
survive driver updates. They are DirectorLink's own: Composer's scheduler is never read or changed.

## Who does what

| Role | Schedules |
| --- | --- |
| viewer, member, doors | see them, and the weather |
| admin | also makes, changes, switches off and deletes them |

A scheduled scene runs like one from a **member's** key: doors and gates in it are always
skipped. Opening a door or gate needs a person.

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
    - heat: hotter than `above` °C (15–45); it runs again only after it has cooled 2° below;
    - wind: stronger than `above` km/h (10–150); again only after it has dropped 10 km/h below;
    - rain: when it starts to rain; again only after an hour without rain;
    - `from`/`to` (optional) limit it to those hours (they may cross midnight); `once_a_day`
      (default on) at most once per day.
- `only_if` (time and sun schedules): `not_raining`, `hotter_than` (°C), `wind_below` (km/h),
  `rain_expected` (today's forecast: a 50% chance or more). They are checked when the schedule is
  due, with the latest weather.
- `if_no_weather`: what a time or sun schedule with `only_if` does when there is no weather data
  (no internet, no location): `run` (the default) or `skip`.
- Read back with `next_run` (time and sun) and `last_run` (`ran`, `skipped`, `failed`; or
  `skipped_by`: `only_if`, `no_weather`).
- At most 50. `version` works as for scenes (409 `VERSION_CONFLICT`).

## Running

- Every minute the controller checks the schedules. A time or sun schedule runs at its minute —
  up to 5 minutes late after a restart, also across midnight — and once; a schedule changed after
  its time starts with the next one. On the day clocks go forward, a time in the skipped hour runs
  when it would have (e.g. 02:30 at 03:30).
- Switching a schedule off and on, or changing it, does not make it run again the same day.
- Weather schedules run when the reading crosses the threshold (or rain starts), on their days,
  within their hours; hours across midnight (22:00–06:00) belong to the day they start.
- What the scheduler remembers (last run, whether a weather schedule may run again) is saved, so a
  restart does not run anything twice.
- Each run is logged (`GET /v1/logs?category=schedules`).

## The weather

- From **Open-Meteo** (open-meteo.com, free, no account): the current temperature, wind,
  precipitation and weather code, and today's high, low and chance of rain. Weather data by
  Open-Meteo.com, CC BY 4.0.
- The **controller** asks `api.open-meteo.com` itself, every 15 minutes while an enabled schedule
  needs the weather, and for an hour after an app shows it. Nothing goes through DirectorLink's
  servers. It sends the project's location rounded to two decimals (about a kilometre).
- The location is the project's latitude and longitude in Composer (project properties). Without
  them, `GET /v1/weather` says `no_location` and weather schedules do not run.
- A reading older than 45 minutes counts as none. After a failed read the controller tries again
  every 5 minutes (and logs the failure once). The last reading is kept across restarts; a
  schedule with "only if" due right after a restart waits a few minutes for a first reading.
- Open-Meteo's free service is for non-commercial use, which a household's own schedules are. An
  installer offering this commercially should check Open-Meteo's terms (they have paid plans).
- `GET /v1/weather` also gives today's sunrise and sunset.

## The app

- **Scenes → Schedules**: the weather at home (with the Open-Meteo credit) and every schedule in a
  sentence — "Sun–Thu at 06:45 · Runs Good morning · Only if it isn’t raining · Next: tomorrow
  06:45" — with an on/off switch for admins.
- The editor: 1 · the scene; 2 · when — At a time, Sun (sunrise or sunset, an hour or half an
  hour before or after), or Weather (heat, rain, wind, with the reading now, the threshold, the
  hours and at most once a day); 3 · the days (with Every day, Sun–Thu and Fri–Sat); 4 · only if;
  then the whole schedule in one sentence, and Save.
