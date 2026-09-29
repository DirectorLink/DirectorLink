# The Jewish calendar engine

**Status: built for DirectorLink 1.2.0 (ADR-037).** How the Shabbat and holiday times, the Hebrew
date and the weekly reading are worked out. What they are used for (the Jewish Calendar property,
Shabbat schedules, `GET /v1/calendar`) is in [SCHEDULES.md](SCHEDULES.md) and
[api/README.md](../api/README.md).

Everything is computed on the controller in plain Lua 5.1, from the project's latitude and
longitude. Nothing is fetched: `scripts/check_package.py` refuses a calendar file that makes a
network call.

## The files

Five pure modules in `driver/src/core/`: no Director, no clock, no time zone. Days are fixed day
numbers (R.D.: R.D. 1 is Monday 1 January of year 1, R.D. 719163 is 1970-01-01, the weekday is
`rd % 7` with 0 for Sunday) and times are seconds from 1970, UTC. Only the service,
`jewish_calendar.lua`, reads the local time.

| File | Works out |
| --- | --- |
| `hebrew_date.lua` | Gregorian and Hebrew dates to and from R.D.; leap years, year and month lengths; month keys |
| `holidays.lua` | The holidays of a Hebrew year, in Israel or abroad: `{ rd, key, day, yom_tov, month }` |
| `parasha.lua` | The weekly reading of each Shabbat, in Israel or abroad (ids 1 to 54) |
| `sun.lua` | Sunrise and sunset: `Sun.times` (minutes of the local day, for schedules) and `Sun.sunsetEpoch` / `Sun.sunriseEpoch` |
| `holy_times.lua` | Holy periods: runs of Shabbat and Yom Tov, with candle lighting and havdalah |

## The Hebrew calendar

From the arithmetic rules in Dershowitz and Reingold, *Calendrical Calculations*, chapter 8 (the
book's own code is not used: its license is not open source). The molad is counted in whole days
and parts (25,920 to a day), never as a fraction of a day, so every number stays below 2^53 and
Lua's doubles are exact; the four postponements (molad zaken, lo ADU Rosh, GaTaRaD, BeTUTaKPaT)
follow. Months are numbered as in the book: 1 Nisan to 6 Elul, 7 Tishrei to 12 Adar (Adar I in a
leap year) and 13 Adar II. A year's month starts are kept for the six years last used.

## Holidays and weekly readings

- **Holy days** (`yom_tov`): Rosh Hashana, Yom Kippur, the first day of Sukkot, Shmini Atzeret and
  Simchat Torah, the first and seventh days of Pesach, and Shavuot; abroad also the second days
  (Sukkot, Pesach, Shavuot), Simchat Torah on 23 Tishrei and the eighth day of Pesach. `day`
  numbers a holiday kept on several days (Rosh Hashana, Chanukah, and abroad the two days).
- **Only shown**: the fasts (moved off Shabbat), Chol HaMoed, Hoshana Rabba, Chanukah, Tu BiShvat,
  Purim and Shushan Purim, Lag BaOmer, Rosh Chodesh (with the month that begins), and the four
  national days, by today's rules from 5764 (2004) on.
- **Weekly readings**: the rules of Shulchan Aruch, Orach Chaim 428:4, as the
  [pyluach](https://github.com/simlist/pyluach) library (MIT License, Meir List) formulates them:
  fill the Shabbatot of the year that have no holiday reading from Vayeilech, Ha'azinu,
  Bereshit onwards, and combine the seven pairs by its conditions. `parasha.lua` is written from
  those rules, not from pyluach's code. A year's readings depend only on its type and the place, and
  the reference years hold all 14 types.
- English names are Hebcal's spelling; the app has its own names in both languages.

## Sunrise and sunset (NOAA)

NOAA's solar calculator, after Meeus, *Astronomical Algorithms* (chapters 25 and 28), for the sun's
upper edge at the horizon at sea level (zenith 90°50′), in two passes: the sun at noon UTC gives
an estimate, the sun at the estimate gives the time. A sunset after local midnight (Reykjavik in
June) is a later moment, never wrapped into the day.

Until 1.2.0 `sun.lua` used the Almanac for Computers method, which agreed with Hebcal's times to the
minute 78% of the time. **Existing sunrise and sunset schedules may move by up to a minute.**
`Sun.times` keeps its signature and its rounding to the nearest minute of the local day.

Hebcal's candle lighting and havdalah come from this same model, to the minute. Hebcal's zmanim
(`/zmanim`) take the sun's apparent radius at its distance instead (16′ ± 0.27′), which moves them
by up to about 2.5 seconds at mid-latitudes: sunrise and sunset agree with them to the minute on
97–99% of days there, always within 3 seconds.

## Holy periods

Shabbat and Yom Tov days that follow each other are one period, with Hebcal's roundings (`b`
minutes before sunset, 20 by default, and `m` after, 42 by default):

- **starts_at**: the sunset before the first day, cut to the minute, less `b`;
- **ends_at**: the sunset of the last day, to the nearest minute, plus `m`;
- candles for a later day: on a Saturday, the day before's sunset cut to the minute less `b` (lit
  before Shabbat); otherwise, after nightfall, that day's sunset to the nearest minute plus `m`.

**The polar rule.** Where a sunset the period needs does not happen (polar day or night), that time
is `nil` and the period is `approximate`; the engine never guesses a time. The service counts an
approximate period's civil days as holy, from 00:00 on the first to 24:00 on the last, and
Shabbat triggers do not run.

## Reference data

`tests/vectors/calendar/` holds Hebcal's own answers (Hebcal.com, CC BY 4.0; see NOTICE), for the
tests `test_hebrew_date`, `test_holidays`, `test_parasha`, `test_sun` and `test_holy_times`:

| File | What |
| --- | --- |
| `hebcal-years.json` | Holidays, Rosh Chodesh and weekly readings, Hebrew years 5760–5820, Israel and abroad |
| `hebcal-months.json` | The first day of every month, 5660–5960 |
| `hebcal-times-<city>.json` | Candle lighting and havdalah (20/42), 2024–2035 |
| `hebcal-sun-<city>.json` | Sunrise and sunset to the second, every day of 2026 |
| `names.json` | Hebcal's English and Hebrew names of the readings and holidays, for the app's tests |
| `api-examples.json` | Hand-written API answers (not from Hebcal) |

The cities are fixed public places by GeoNames id: Tel Aviv (293397, Israel), New York (5128581),
Buenos Aires (3435910), Reykjavik (3413829) and Tromsø (3133895; 3133880 is Trondheim).

To make them again (by hand, not in CI; Node 22, no dependencies, about 500 requests and five
minutes):

```bash
node scripts/make_calendar_vectors.mjs
```

It asks only `https://www.hebcal.com`, always with `b=20&m=42` and `i=on` or `i=off`, only for those
places, and waits 300 ms between requests. It takes no arguments and no coordinates, so no home's
location is ever sent. It reads Hebcal's API terms first and stops if they no longer say CC BY 4.0.
Each file records the attribution, the queries and the date.

What the tests found against them: every Hebrew date, holiday and weekly reading the same in both
places (7,280 holidays, 6,370 Shabbatot, 3,422 month starts); candle lighting and havdalah the
same to the minute in Tel Aviv, New York, Buenos Aires and Reykjavik (100%), and in Tromsø 99.6%,
the rest within a minute.

```bash
lua5.1 driver/tests/run.lua test_hebrew_date test_holidays test_parasha test_sun test_holy_times
```
