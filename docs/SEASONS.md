# Seasons and championships

Main menu, **Season / championship**. Saved seasons are listed there to
resume (or delete); **New season** builds one.

## Building a season

- **Name**, then the rules:
  - **Points**: F1 (25-18-15-12-10-8-6-4-2-1), F1 2003-09, F1 1991-2002,
    MotoGP, IndyCar, "Everyone scores" (last place gets 1), or Custom (type
    a list such as `30,24,20,16,12`).
  - **Pole position** bonus (none, +1, +3) and **Fastest lap** bonus (+1 if
    that driver finishes in the top 10).
  - **Qualifying**: *Driven* (a 3-lap session before every race; your best
    lap sets your grid slot), *Quick* (the grid is worked out from cars,
    driver pace, wet skill and a little luck), or *Off* (the Grid order
    setting decides).
- **Calendar**: pick a Track, Laps, Weather, Start time and Weather changes,
  then **Add round**. Repeat for every round. **Random calendar (6 rounds)**
  and **Every track** fill it in one go using the current Laps, Weather and
  Start time. **Remove last round** takes one off.
- The race settings below the calendar (class, AI drivers, difficulty,
  clock speed, damage, safety car, fuel, tyre wear, mandatory stops,
  upgrades) apply to every round.

## Playing it

The season hub shows the next round, the driver and team standings, the
calendar with each round's winner, and (from season 2 on) the driver market
news. **Start qualifying** / **Start race** plays the next session offline;
**Host online season** opens a lobby for it. The season saves itself after
every session.

- **The field**: whole teams race. Teams are drawn from the 12 teams in
  `modules/ai/data/drivers.json` until the grid has the chosen number of AI
  drivers; each team enters its two best drivers in one car model (one class
  for a single-class season, classes taken in turn for multi-class). The AI
  drivers keep their team, car and traits for the whole season.
- **You** race for your own team ("Team <your name>"). You can change car
  between rounds within the season's class. Your player name is who you are
  in the season, so keep the same name.
- **Standings**: drivers by points, ties broken by countback (most wins, then
  most seconds...). Teams add up their drivers' points.
- **Prize money**: every season race pays into your team budget (garage),
  1.25x a single race of the same length.
- **No do-overs**: restart is off in season races.

## Online seasons

The host hosts from the season hub. Friends join the usual way; the lobby
shows the season, the next round and the top of both standings, and the race
settings come from the season (the host can't change them in the lobby).
Players are matched to the season by name, so the same group can carry on
another night: the host resumes the season and hosts again. A new player
joins the standings from the round they first race. Each player's prize
money goes into their own team on their own PC.

## The season after

When every round is done the hub shows the champion and **Start next
season**: the same calendar, rules and players, and a year on for every AI
driver:

- drivers under 27 grow towards their potential, drivers over 33 slowly
  lose a little, and drivers reaching 39 retire;
- a team whose driver finished in the bottom third may drop them (60%);
- open seats go to the best free agent (rating now plus potential) or, 30%
  of the time, a rookie (18-20, high potential) with a made-up name.

The news lists every change.

## Files

- `user://seasons/<id>.json`: the season (rules, calendar, field, results).
- `user://seasons/<id>/r03_qualifying.json`, `r03_race.json`: each session's
  full race log from the race data module (laps, sectors, gaps, feed, weather).

## For code

`modules/season` (see `module.json`): `Season` (plan_next, record,
standings, next_season, to_dict/from_dict), `PointsSystem`, `SeasonResults`
(classification from a finished `RaceSim` plus the telemetry log),
`SeasonStore` (save, load, list, delete). The race scene records sessions
(host or offline only) and tells `_on_season_round_done` about the player's
own car on every machine. Online, `Net.start_planner` plans season races and
`Net.season_info` carries the standings to the lobby.

Command line, for tests and servers:
`--single --season 2 --qualifying driven --autodrive --quit-after-season`,
`--server --season 1 ...`, `--resume-season latest`,
`--menu-page season_hub --menu-shot out.png`.
