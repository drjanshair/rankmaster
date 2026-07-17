# RankMaster

RankMaster is a small SourceMod statistics plugin for CS:GO competitive servers. It records live competitive play, calculates contextual map impact, keeps a persistent skill rating, stores lifetime data, and shows every tracked statistic for both the current map and all time.

It was designed as a deliberately smaller alternative to [Levels Ranks Core](https://github.com/levelsranks/pawn-levels_ranks-core).

## Features

- Tracks only classic competitive (`game_type 0`, `game_mode 1`) live rounds.
- Ignores warmup, bots, spectators, team kills, and rounds without players on both teams.
- Stores lifetime data in SQLite automatically.
- Optionally uses a configured MySQL database.
- Ranks players with a persistent match-result rating, adjusted by contextual combat, utility, objective, and clutch impact.
- Tracks kills, deaths, assists, K/D, headshot rate, damage, utility damage, enemies flashed, grenade usage, bomb objectives, MVPs, round wins, map impact, rating, peak rating, and last rating change.
- Shows the map top three and each player's full map card at match end.
- Provides full map and all-time stat panels.

## Commands

| Chat/console command | Result |
| --- | --- |
| `!rank` or `!stats` | All-time leaderboard position, tier, and every lifetime stat |
| `!mapstats` | Current-map position, tier, and every map stat |
| `!top` | All-time top 10 |

## Install

1. Compile `scripting/rankmaster.sp` with SourceMod 1.10 or newer.
2. Copy `rankmaster.smx` to `addons/sourcemod/plugins/`.
3. Restart the server or run `sm plugins load rankmaster`.
4. Edit the generated `cfg/sourcemod/rankmaster.cfg` if needed.

By default the database is stored at `addons/sourcemod/data/sqlite/rankmaster.sq3`. No database setup is required.

To use MySQL, add this entry to `addons/sourcemod/configs/databases.cfg` before loading the plugin:

```text
"rankmaster"
{
    "driver"    "mysql"
    "host"      "127.0.0.1"
    "database"  "rankmaster"
    "user"      "user"
    "pass"      "password"
}
```

## Configuration

- `rankmaster_competitive_only 1` requires classic competitive game mode.
- `rankmaster_force_live 0` can be set to `1` for a custom scrim/match configuration that does not report `game_mode 1`. Warmup remains excluded.
- `rankmaster_min_team_players 1` is useful for testing. Set it to `5` on a strict 5v5 server.

## Ranking

Every player starts at `1000` rating and has a visible tier: Rookie, Bronze, Silver, Gold, Master, Elite, or Legend. All-time leaderboard position is based on persistent rating, not raw lifetime stat volume.

At match end, RankMaster calculates an Elo-style expected result from each team's average rating. The normal win/loss delta is scaled by the final score margin, so a blowout moves more rating than a close result without allowing a winner to lose rating. The result creates a bounded team rating pool. Individual performance changes how that pool is split inside each team, so a strong losing player can lose less, but cannot gain rating from a loss.

Map impact is contextual rather than a flat kill/death formula. It considers:

- opening kills, late-round kills, man advantage or disadvantage, and equipment disadvantage;
- damage contribution, flash assists, trade kills, and traded-player credit;
- deaths, especially early deaths;
- utility damage, enemies flashed, bomb plants, bomb defuses, and clutches;
- symmetric clawbacks for low-signal desperation and last-opponent cleanup kills.

The current tier thresholds are:

| Tier | Rating |
| --- | ---: |
| Rookie | below 800 |
| Bronze | 800+ |
| Silver | 1000+ |
| Gold | 1200+ |
| Master | 1400+ |
| Elite | 1600+ |
| Legend | 1800+ |

The entry point and gameplay events live in `scripting/rankmaster.sp`. Persistence, impact calculation, rating, and UI code are split into the `.inc` files under `scripting/rankmaster/` and are compiled into the same plugin.

The main tuning points are `CalculateKillValue()` and `ApplyKillImpact()` in `impact.inc`, `ApplyMatchRatingUpdate()` and `GetMatchKFactor()` in `rating.inc`, and `GetTier()` in `ui.inc`.

## Scope

This initial version targets CS:GO through SourceMod, matching the platform of the reference project. CS2 needs a CounterStrikeSharp port because SourceMod plugins do not run on CS2.
