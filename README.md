# RankMaster

RankMaster is a lightweight SourceMod ranking and statistics plugin for CS:GO competitive servers. It tracks persistent player stats, map impact, and an Elo-style rating that is weighted by team result, score margin, and contextual round impact.

## Features

- Persistent player rating, peak rating, wins, losses, and match count
- Per-map impact ranking shown at match end
- Contextual kill value based on first kill, alive advantage, late-round state, equipment value, headshots, trades, damage contribution, and flash assists
- Utility, plant, defuse, MVP, round win, K/D, headshot, accuracy, and damage tracking
- Score-margin rating scaling so close matches move less rating than blowouts
- Round-start tracking snapshots to avoid mid-round join/leave events partially affecting ranked stats
- SQLite fallback if no SourceMod database config is provided

## Installation

1. Copy the source file to your SourceMod scripting folder:

   ```text
   addons/sourcemod/scripting/rankmaster.sp
   ```

2. Compile it with SourceMod's compiler:

   ```bash
   spcomp rankmaster.sp
   ```

3. Copy the compiled plugin to:

   ```text
   addons/sourcemod/plugins/rankmaster.smx
   ```

4. Restart the server or load the plugin:

   ```text
   sm plugins load rankmaster
   ```

## Database

RankMaster first tries to connect to a SourceMod database entry named `rankmaster`.

Example `addons/sourcemod/configs/databases.cfg` entry:

```text
"rankmaster"
{
    "driver"    "sqlite"
    "database"  "rankmaster"
}
```

If the `rankmaster` database entry is missing, the plugin falls back to a local SQLite database named `rankmaster`.

## Commands

```text
sm_rank      Show your all-time rank and stats
sm_stats     Alias for sm_rank
sm_mapstats  Show your current-map rank and stats
sm_top       Show the all-time top 10
```

## ConVars

These are auto-generated in `cfg/sourcemod/rankmaster.cfg`.

```text
rankmaster_competitive_only  1  Only collect stats in classic competitive mode
rankmaster_force_live        0  Force tracking for custom competitive configs, while still ignoring warmup
rankmaster_min_team_players  1  Minimum human players required on each team
```

## Rating Model

Players start at `1000` rating. At match end, RankMaster calculates the expected result from the average rating of the current T and CT teams. The winning side gains rating and the losing side loses rating. Close games use a smaller rating pool, while blowouts use a larger pool.

Within each team, the rating change is distributed by map impact:

- Higher-impact players receive a larger share of rating gained.
- Lower-impact players receive a larger share of rating lost.

## Notes

RankMaster is intended for competitive-style CS:GO servers. For custom pug systems with side swaps or team reassignment, rating accuracy can be improved further by storing match team identity separately from the current T/CT side.

## License

GPL-3.0
