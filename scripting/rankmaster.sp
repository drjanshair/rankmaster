#include <sourcemod>
#include <sdktools>
#include <cstrike>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
	name = "RankMaster",
	author = "OpenAI",
	description = "Competitive match statistics and persistent player ranks",
	version = "1.0.0",
	url = ""
};

enum Stat
{
	Stat_Kills,
	Stat_Deaths,
	Stat_Assists,
	Stat_Headshots,
	Stat_Shots,
	Stat_Hits,
	Stat_Damage,
	Stat_UtilityDamage,
	Stat_EnemiesFlashed,
	Stat_Grenades,
	Stat_Plants,
	Stat_Defuses,
	Stat_Mvps,
	Stat_RoundWins,
	Stat_Rounds,
	Stat_Count
};

Database g_Database;
int g_MapStats[MAXPLAYERS + 1][Stat_Count];
int g_AllStats[MAXPLAYERS + 1][Stat_Count];
int g_Matches[MAXPLAYERS + 1];
float g_Rating[MAXPLAYERS + 1];
float g_PeakRating[MAXPLAYERS + 1];
int g_RatedMatches[MAXPLAYERS + 1];
int g_RatingWins[MAXPLAYERS + 1];
int g_RatingLosses[MAXPLAYERS + 1];
float g_MapImpact[MAXPLAYERS + 1];
float g_LastRatingChange[MAXPLAYERS + 1];
float g_RoundDesperationImpact[MAXPLAYERS + 1];
float g_RoundCleanupImpact[MAXPLAYERS + 1];
int g_RoundKills[MAXPLAYERS + 1];
int g_RoundDamage[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_ClutchSize[MAXPLAYERS + 1];
float g_LastDeathTime[4];
int g_LastKiller[4];
int g_LastVictim[4];
int g_TotalRoundKills;
bool g_Loaded[MAXPLAYERS + 1];
bool g_MapSaved[MAXPLAYERS + 1];
bool g_Finalized;
bool g_RoundTracked;
bool g_RoundParticipant[MAXPLAYERS + 1];

ConVar g_GameType;
ConVar g_GameMode;
ConVar g_CompetitiveOnly;
ConVar g_ForceLive;
ConVar g_MinTeamPlayers;

public void OnPluginStart()
{
	g_CompetitiveOnly = CreateConVar("rankmaster_competitive_only", "1", "Only collect stats in classic competitive mode.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_ForceLive = CreateConVar("rankmaster_force_live", "0", "Force tracking for custom competitive configs (warmup is still ignored).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_MinTeamPlayers = CreateConVar("rankmaster_min_team_players", "1", "Minimum human players required on each team.", FCVAR_NOTIFY, true, 1.0, true, 5.0);
	AutoExecConfig(true, "rankmaster");

	g_GameType = FindConVar("game_type");
	g_GameMode = FindConVar("game_mode");

	RegConsoleCmd("sm_rank", Command_AllStats, "Show your all-time rank and stats");
	RegConsoleCmd("sm_stats", Command_AllStats, "Show your all-time rank and stats");
	RegConsoleCmd("sm_mapstats", Command_MapStats, "Show your current-map rank and stats");
	RegConsoleCmd("sm_top", Command_Top, "Show the all-time top 10");

	HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("weapon_fire", Event_WeaponFire, EventHookMode_Post);
	HookEvent("player_hurt", Event_PlayerHurt, EventHookMode_Post);
	HookEvent("player_blind", Event_PlayerBlind, EventHookMode_Post);
	HookEvent("hegrenade_detonate", Event_GrenadeUsed, EventHookMode_Post);
	HookEvent("flashbang_detonate", Event_GrenadeUsed, EventHookMode_Post);
	HookEvent("smokegrenade_detonate", Event_GrenadeUsed, EventHookMode_Post);
	HookEvent("decoy_detonate", Event_GrenadeUsed, EventHookMode_Post);
	HookEvent("molotov_detonate", Event_GrenadeUsed, EventHookMode_Post);
	HookEvent("bomb_planted", Event_BombPlanted, EventHookMode_Post);
	HookEvent("bomb_defused", Event_BombDefused, EventHookMode_Post);
	HookEvent("round_mvp", Event_RoundMvp, EventHookMode_Post);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Post);
	HookEvent("cs_win_panel_match", Event_MatchEnd, EventHookMode_PostNoCopy);

	ConnectDatabase();

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client))
		{
			LoadPlayer(client);
		}
	}
}

public void OnMapStart()
{
	g_Finalized = false;
	for (int client = 1; client <= MaxClients; client++)
	{
		ResetMapStats(client);
	}
	ResetRoundContext();
}

public void OnMapEnd()
{
	FinalizeMatch(false);
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	ResetPlayer(client);
	LoadPlayer(client);
}

public void OnClientDisconnect(int client)
{
	if (!IsFakeClient(client) && g_Loaded[client])
	{
		if (!g_Finalized && !g_MapSaved[client] && g_MapStats[client][Stat_Rounds] >= 3)
		{
			ApplyLeaverPenalty(client);
		}
		SavePlayer(client, false);
	}
	ResetPlayer(client);
}

void ConnectDatabase()
{
	char error[256];
	g_Database = SQL_Connect("rankmaster", true, error, sizeof(error));
	if (g_Database == null)
	{
		LogMessage("Database config 'rankmaster' not found; using local SQLite storage.");
		g_Database = SQLite_UseDatabase("rankmaster", error, sizeof(error));
	}

	if (g_Database == null)
	{
		SetFailState("Could not connect to database: %s", error);
	}

	char query[2048];
	Format(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS rankmaster_players ("
		... "steamid VARCHAR(32) PRIMARY KEY, name VARCHAR(128) NOT NULL, score REAL NOT NULL DEFAULT 0, matches INTEGER NOT NULL DEFAULT 0, "
		... "kills INTEGER NOT NULL DEFAULT 0, deaths INTEGER NOT NULL DEFAULT 0, assists INTEGER NOT NULL DEFAULT 0, headshots INTEGER NOT NULL DEFAULT 0, "
		... "shots INTEGER NOT NULL DEFAULT 0, hits INTEGER NOT NULL DEFAULT 0, damage INTEGER NOT NULL DEFAULT 0, utility_damage INTEGER NOT NULL DEFAULT 0, "
		... "enemies_flashed INTEGER NOT NULL DEFAULT 0, grenades INTEGER NOT NULL DEFAULT 0, plants INTEGER NOT NULL DEFAULT 0, defuses INTEGER NOT NULL DEFAULT 0, "
		... "mvps INTEGER NOT NULL DEFAULT 0, round_wins INTEGER NOT NULL DEFAULT 0, rounds INTEGER NOT NULL DEFAULT 0, last_seen INTEGER NOT NULL DEFAULT 0)");

	if (!SQL_FastQuery(g_Database, query))
	{
		SQL_GetError(g_Database, error, sizeof(error));
		SetFailState("Could not create RankMaster table: %s", error);
	}

	Format(query, sizeof(query),
		"CREATE TABLE IF NOT EXISTS rankmaster_ratings ("
		... "steamid VARCHAR(32) PRIMARY KEY, rating REAL NOT NULL DEFAULT 1000, peak_rating REAL NOT NULL DEFAULT 1000, "
		... "rated_matches INTEGER NOT NULL DEFAULT 0, wins INTEGER NOT NULL DEFAULT 0, losses INTEGER NOT NULL DEFAULT 0, last_change REAL NOT NULL DEFAULT 0)");
	if (!SQL_FastQuery(g_Database, query))
	{
		SQL_GetError(g_Database, error, sizeof(error));
		SetFailState("Could not create RankMaster ratings table: %s", error);
	}
}

void LoadPlayer(int client)
{
	if (g_Database == null || !IsHumanClient(client))
	{
		return;
	}

	char steamId[32];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true))
	{
		CreateTimer(2.0, Timer_RetryLoad, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
		return;
	}

	char query[1024];
	Format(query, sizeof(query), "SELECT matches,kills,deaths,assists,headshots,shots,hits,damage,utility_damage,enemies_flashed,grenades,plants,defuses,mvps,round_wins,rounds FROM rankmaster_players WHERE steamid='%s'", steamId);
	DBResultSet rows = SQL_Query(g_Database, query);
	if (rows == null)
	{
		LogDatabaseError("loading player");
		return;
	}

	if (rows.FetchRow())
	{
		g_Matches[client] = rows.FetchInt(0);
		for (int stat = 0; stat < view_as<int>(Stat_Count); stat++)
		{
			g_AllStats[client][stat] = rows.FetchInt(stat + 1);
		}
	}
	delete rows;

	g_Rating[client] = 1000.0;
	g_PeakRating[client] = 1000.0;
	Format(query, sizeof(query), "SELECT rating,peak_rating,rated_matches,wins,losses FROM rankmaster_ratings WHERE steamid='%s'", steamId);
	rows = SQL_Query(g_Database, query);
	if (rows == null)
	{
		LogDatabaseError("loading player rating");
		return;
	}
	if (rows.FetchRow())
	{
		g_Rating[client] = rows.FetchFloat(0);
		g_PeakRating[client] = rows.FetchFloat(1);
		g_RatedMatches[client] = rows.FetchInt(2);
		g_RatingWins[client] = rows.FetchInt(3);
		g_RatingLosses[client] = rows.FetchInt(4);
	}
	delete rows;
	g_Loaded[client] = true;
}

public Action Timer_RetryLoad(Handle timer, int userId)
{
	int client = GetClientOfUserId(userId);
	if (client > 0 && !g_Loaded[client])
	{
		LoadPlayer(client);
	}
	return Plugin_Stop;
}

void SavePlayer(int client, bool countMatch)
{
	if (g_Database == null || !g_Loaded[client])
	{
		return;
	}

	if (countMatch)
	{
		g_Matches[client]++;
		g_MapSaved[client] = true;
	}
	char steamId[32], name[MAX_NAME_LENGTH], escapedName[MAX_NAME_LENGTH * 2 + 1], query[4096];
	if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId), true))
	{
		return;
	}
	GetClientName(client, name, sizeof(name));
	g_Database.Escape(name, escapedName, sizeof(escapedName));

	Format(query, sizeof(query),
		"REPLACE INTO rankmaster_players (steamid,name,score,matches,kills,deaths,assists,headshots,shots,hits,damage,utility_damage,enemies_flashed,grenades,plants,defuses,mvps,round_wins,rounds,last_seen) "
		... "VALUES ('%s','%s',%.3f,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d)",
		steamId, escapedName, g_Rating[client], g_Matches[client],
		g_AllStats[client][Stat_Kills], g_AllStats[client][Stat_Deaths], g_AllStats[client][Stat_Assists], g_AllStats[client][Stat_Headshots],
		g_AllStats[client][Stat_Shots], g_AllStats[client][Stat_Hits], g_AllStats[client][Stat_Damage], g_AllStats[client][Stat_UtilityDamage],
		g_AllStats[client][Stat_EnemiesFlashed], g_AllStats[client][Stat_Grenades], g_AllStats[client][Stat_Plants], g_AllStats[client][Stat_Defuses],
		g_AllStats[client][Stat_Mvps], g_AllStats[client][Stat_RoundWins], g_AllStats[client][Stat_Rounds], GetTime());

	if (!SQL_FastQuery(g_Database, query))
	{
		LogDatabaseError("saving player");
	}

	Format(query, sizeof(query),
		"REPLACE INTO rankmaster_ratings (steamid,rating,peak_rating,rated_matches,wins,losses,last_change) VALUES ('%s',%.3f,%.3f,%d,%d,%d,%.3f)",
		steamId, g_Rating[client], g_PeakRating[client], g_RatedMatches[client], g_RatingWins[client], g_RatingLosses[client], g_LastRatingChange[client]);
	if (!SQL_FastQuery(g_Database, query))
	{
		LogDatabaseError("saving player rating");
	}
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
	if (!ShouldTrack()) return;
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	int assister = GetClientOfUserId(event.GetInt("assister"));
	bool headshot = event.GetBool("headshot");
	bool flashAssist = event.GetBool("assistedflash");
	bool validAssister = IsValidAssistClient(assister, attacker, victim);
	bool validFlashAssist = flashAssist && validAssister;

	AddStat(victim, Stat_Deaths, 1);
	if (ValidOpponent(attacker, victim))
	{
		AddStat(attacker, Stat_Kills, 1);
		if (headshot) AddStat(attacker, Stat_Headshots, 1);

		int attackerTeam = GetClientTeam(attacker);
		int victimTeam = GetClientTeam(victim);
		bool traded = g_LastKiller[attackerTeam] == victim && GetGameTime() - g_LastDeathTime[attackerTeam] <= 5.0;
		float killValue = CalculateKillValue(attacker, victim, headshot);
		ApplyKillImpact(attacker, victim, validAssister ? assister : 0, killValue, validFlashAssist, traded);

		int attackerAlive = CountAliveOnTeam(attackerTeam);
		int victimAliveBefore = CountAliveOnTeam(victimTeam) + 1;
		if (attackerAlive == 1 && victimAliveBefore >= 3)
		{
			g_RoundDesperationImpact[attacker] += killValue * 0.50;
		}
		else if (attackerAlive - victimAliveBefore >= 2 && victimAliveBefore <= 2)
		{
			g_RoundCleanupImpact[attacker] += killValue * 0.50;
		}

		g_RoundKills[attacker]++;
		g_TotalRoundKills++;
		g_LastKiller[victimTeam] = attacker;
		g_LastVictim[victimTeam] = victim;
		g_LastDeathTime[victimTeam] = GetGameTime();

		if (validAssister)
		{
			AddStat(assister, Stat_Assists, 1);
		}
	}
	UpdateClutchCandidates();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	ResetRoundContext();
	g_RoundTracked = CanTrackCurrentRound();
	if (!g_RoundTracked)
	{
		return;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		g_RoundParticipant[client] = IsTrackingClient(client);
	}
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
	if (!ShouldTrack()) return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	AddStat(client, Stat_Shots, 1);
}

public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
	if (!ShouldTrack()) return;
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (!ValidOpponent(attacker, victim)) return;

	int damage = event.GetInt("dmg_health");
	AddStat(attacker, Stat_Hits, 1);
	AddStat(attacker, Stat_Damage, damage);
	g_RoundDamage[attacker][victim] += damage;

	char weapon[32];
	event.GetString("weapon", weapon, sizeof(weapon));
	if (StrEqual(weapon, "hegrenade") || StrEqual(weapon, "inferno") || StrEqual(weapon, "molotov") || StrEqual(weapon, "incgrenade"))
	{
		AddStat(attacker, Stat_UtilityDamage, damage);
		AddImpact(attacker, float(damage) * 0.002);
	}
}

public void Event_PlayerBlind(Event event, const char[] name, bool dontBroadcast)
{
	if (!ShouldTrack()) return;
	int victim = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	if (ValidOpponent(attacker, victim))
	{
		AddStat(attacker, Stat_EnemiesFlashed, 1);
		AddImpact(attacker, 0.025);
	}
}

public void Event_GrenadeUsed(Event event, const char[] name, bool dontBroadcast)
{
	if (!ShouldTrack()) return;
	AddStat(GetClientOfUserId(event.GetInt("userid")), Stat_Grenades, 1);
}

public void Event_BombPlanted(Event event, const char[] name, bool dontBroadcast)
{
	if (!ShouldTrack()) return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	AddStat(client, Stat_Plants, 1);
	AddImpact(client, 0.20);
}

public void Event_BombDefused(Event event, const char[] name, bool dontBroadcast)
{
	if (!ShouldTrack()) return;
	int client = GetClientOfUserId(event.GetInt("userid"));
	AddStat(client, Stat_Defuses, 1);
	AddImpact(client, 0.60);
}

public void Event_RoundMvp(Event event, const char[] name, bool dontBroadcast)
{
	if (ShouldTrack()) AddStat(GetClientOfUserId(event.GetInt("userid")), Stat_Mvps, 1);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (!ShouldTrack()) return;
	int winner = event.GetInt("winner");
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsRoundTrackingClient(client)) continue;
		AddStat(client, Stat_Rounds, 1);
		if (GetClientTeam(client) == winner) AddStat(client, Stat_RoundWins, 1);
		if (GetClientTeam(client) != winner && g_RoundDesperationImpact[client] > 0.0)
		{
			AddImpact(client, -g_RoundDesperationImpact[client] * 0.75);
		}
		else if (GetClientTeam(client) == winner && g_RoundCleanupImpact[client] > 0.0)
		{
			AddImpact(client, -g_RoundCleanupImpact[client] * 0.75);
		}
		if (GetClientTeam(client) == winner && g_ClutchSize[client] >= 2 && IsPlayerAlive(client))
		{
			AddImpact(client, MinFloat(1.50, 0.60 + float(g_ClutchSize[client] - 2) * 0.30));
		}
	}
}

public void Event_MatchEnd(Event event, const char[] name, bool dontBroadcast)
{
	FinalizeMatch(true);
}

void FinalizeMatch(bool display)
{
	if (g_Finalized) return;
	g_Finalized = true;

	if (display)
	{
		ApplyMatchRatingUpdate();
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsHumanClient(client) && g_Loaded[client] && g_MapStats[client][Stat_Rounds] > 0)
		{
			SavePlayer(client, display);
		}
	}

	if (display)
	{
		CreateTimer(1.0, Timer_ShowMatchResults, 0, TIMER_FLAG_NO_MAPCHANGE);
	}
}

public Action Timer_ShowMatchResults(Handle timer, any data)
{
	int topClients[3] = {0, 0, 0};
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsTrackingClient(client) || g_MapStats[client][Stat_Rounds] == 0) continue;
		float score = g_MapImpact[client];
		for (int place = 0; place < 3; place++)
		{
			if (topClients[place] == 0 || score > g_MapImpact[topClients[place]])
			{
				for (int move = 2; move > place; move--) topClients[move] = topClients[move - 1];
				topClients[place] = client;
				break;
			}
		}
	}

	PrintToChatAll("\x04[RankMaster]\x01 Map ranking:");
	for (int place = 0; place < 3; place++)
	{
		int client = topClients[place];
		if (client > 0)
		{
			PrintToChatAll("\x04#%d\x01 %N - %.2f impact, %.0f rating (%.1f), %d K / %d D / %d A",
				place + 1, client, g_MapImpact[client], g_Rating[client], g_LastRatingChange[client],
				g_MapStats[client][Stat_Kills], g_MapStats[client][Stat_Deaths], g_MapStats[client][Stat_Assists]);
		}
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsTrackingClient(client) && g_MapStats[client][Stat_Rounds] > 0)
		{
			ShowStatsPanel(client, true);
		}
	}
	return Plugin_Stop;
}

public Action Command_AllStats(int client, int args)
{
	if (!RequirePlayer(client)) return Plugin_Handled;
	ShowStatsPanel(client, false);
	return Plugin_Handled;
}

public Action Command_MapStats(int client, int args)
{
	if (!RequirePlayer(client)) return Plugin_Handled;
	ShowStatsPanel(client, true);
	return Plugin_Handled;
}

public Action Command_Top(int client, int args)
{
	if (!RequirePlayer(client) || g_Database == null) return Plugin_Handled;
	DBResultSet rows = SQL_Query(g_Database,
		"SELECT p.name,r.rating,p.kills,p.deaths,p.headshots,r.peak_rating FROM rankmaster_ratings r "
		... "INNER JOIN rankmaster_players p ON p.steamid=r.steamid ORDER BY r.rating DESC LIMIT 10");
	if (rows == null)
	{
		LogDatabaseError("loading leaderboard");
		return Plugin_Handled;
	}

	Panel panel = new Panel();
	panel.SetTitle("RankMaster — All-time Top 10");
	char playerName[128], line[256];
	int place = 0;
	while (rows.FetchRow())
	{
		place++;
		rows.FetchString(0, playerName, sizeof(playerName));
		Format(line, sizeof(line), "#%d %s - %.0f rating | peak %.0f | %d/%d | %d HS",
			place, playerName, rows.FetchFloat(1), rows.FetchFloat(5), rows.FetchInt(2), rows.FetchInt(3), rows.FetchInt(4));
		panel.DrawText(line);
	}
	panel.DrawItem("Close");
	panel.Send(client, PanelHandler_Close, 20);
	delete panel;
	delete rows;
	return Plugin_Handled;
}

void ShowStatsPanel(int client, bool mapStats)
{
	int stats[Stat_Count];
	for (int stat = 0; stat < view_as<int>(Stat_Count); stat++)
	{
		stats[stat] = mapStats ? g_MapStats[client][stat] : g_AllStats[client][stat];
	}
	float score = mapStats ? g_MapImpact[client] : g_Rating[client];
	int position = mapStats ? GetMapPosition(client) : GetDatabasePosition(score);
	float kd = float(stats[Stat_Kills]) / float(stats[Stat_Deaths] > 0 ? stats[Stat_Deaths] : 1);
	float hs = stats[Stat_Kills] > 0 ? float(stats[Stat_Headshots]) * 100.0 / float(stats[Stat_Kills]) : 0.0;
	float accuracy = stats[Stat_Shots] > 0 ? float(stats[Stat_Hits]) * 100.0 / float(stats[Stat_Shots]) : 0.0;
	char tier[16];
	GetTier(g_Rating[client], tier, sizeof(tier));

	Panel panel = new Panel();
	char line[256];
	Format(line, sizeof(line), "RankMaster — %s Stats", mapStats ? "Map" : "All-time");
	panel.SetTitle(line);
	if (mapStats)
	{
		Format(line, sizeof(line), "Map rank: #%d | Impact: %.2f | Rating change: %.1f", position, score, g_LastRatingChange[client]);
		panel.DrawText(line);
		Format(line, sizeof(line), "All-time: %s | %.0f rating | Peak %.0f", tier, g_Rating[client], g_PeakRating[client]);
		panel.DrawText(line);
	}
	else
	{
		Format(line, sizeof(line), "Rank: #%d | %s | %.0f rating", position, tier, score);
		panel.DrawText(line);
		Format(line, sizeof(line), "Competitive matches: %d | Rated: %d | W/L: %d/%d",
			g_Matches[client], g_RatedMatches[client], g_RatingWins[client], g_RatingLosses[client]);
		panel.DrawText(line);
		Format(line, sizeof(line), "Peak rating: %.0f | Last change: %.1f", g_PeakRating[client], g_LastRatingChange[client]);
		panel.DrawText(line);
	}
	Format(line, sizeof(line), "Kills: %d | Deaths: %d | Assists: %d", stats[Stat_Kills], stats[Stat_Deaths], stats[Stat_Assists]); panel.DrawText(line);
	Format(line, sizeof(line), "K/D: %.2f | Headshots: %d (%.1f%%)", kd, stats[Stat_Headshots], hs); panel.DrawText(line);
	Format(line, sizeof(line), "Damage: %d | Hits/Shots: %d/%d (%.1f%%)", stats[Stat_Damage], stats[Stat_Hits], stats[Stat_Shots], accuracy); panel.DrawText(line);
	Format(line, sizeof(line), "Utility damage: %d | Enemies flashed: %d", stats[Stat_UtilityDamage], stats[Stat_EnemiesFlashed]); panel.DrawText(line);
	Format(line, sizeof(line), "Grenades used: %d | Plants: %d | Defuses: %d", stats[Stat_Grenades], stats[Stat_Plants], stats[Stat_Defuses]); panel.DrawText(line);
	Format(line, sizeof(line), "MVPs: %d | Round wins: %d/%d", stats[Stat_Mvps], stats[Stat_RoundWins], stats[Stat_Rounds]); panel.DrawText(line);
	panel.DrawItem("Close");
	panel.Send(client, PanelHandler_Close, 25);
	delete panel;
}

public int PanelHandler_Close(Menu menu, MenuAction action, int param1, int param2)
{
	return 0;
}

void GetTier(float rating, char[] tier, int maxLength)
{
	if (rating >= 1800.0) strcopy(tier, maxLength, "Legend");
	else if (rating >= 1600.0) strcopy(tier, maxLength, "Elite");
	else if (rating >= 1400.0) strcopy(tier, maxLength, "Master");
	else if (rating >= 1200.0) strcopy(tier, maxLength, "Gold");
	else if (rating >= 1000.0) strcopy(tier, maxLength, "Silver");
	else if (rating >= 800.0) strcopy(tier, maxLength, "Bronze");
	else strcopy(tier, maxLength, "Rookie");
}

float MinFloat(float first, float second)
{
	return first < second ? first : second;
}

float MaxFloat(float first, float second)
{
	return first > second ? first : second;
}

float ClampFloat(float value, float minimum, float maximum)
{
	if (value < minimum) return minimum;
	if (value > maximum) return maximum;
	return value;
}

void AddImpact(int client, float amount)
{
	if (!IsRoundTrackingClient(client)) return;
	g_MapImpact[client] += amount;
}

float CalculateKillValue(int attacker, int victim, bool headshot)
{
	int attackerTeam = GetClientTeam(attacker);
	int victimTeam = GetClientTeam(victim);
	int attackerAlive = CountAliveOnTeam(attackerTeam);
	int victimAliveBefore = CountAliveOnTeam(victimTeam) + 1;
	float value = 1.0;

	if (g_TotalRoundKills == 0)
	{
		value *= 1.20;
	}

	int aliveDiff = attackerAlive - victimAliveBefore;
	if (aliveDiff >= 2)
	{
		value *= 0.55;
	}
	else if (aliveDiff <= -2)
	{
		value *= 1.25;
	}

	if (attackerAlive + victimAliveBefore <= 5)
	{
		value *= 1.20;
	}

	value *= GetEquipmentMultiplier(attacker, victim);
	if (headshot)
	{
		value *= 1.02;
	}

	if (g_RoundKills[attacker] == 1) value *= 0.95;
	else if (g_RoundKills[attacker] == 2) value *= 0.85;
	else if (g_RoundKills[attacker] == 3) value *= 0.75;
	else if (g_RoundKills[attacker] >= 4) value *= 0.65;

	return ClampFloat(value, 0.20, 2.00);
}

float GetEquipmentMultiplier(int attacker, int victim)
{
	int resource = GetPlayerResourceEntity();
	if (resource == -1 || !HasEntProp(resource, Prop_Send, "m_iEquipmentValue"))
	{
		return 1.0;
	}

	int attackerValue = GetEntProp(resource, Prop_Send, "m_iEquipmentValue", _, attacker);
	int victimValue = GetEntProp(resource, Prop_Send, "m_iEquipmentValue", _, victim);
	return ClampFloat(float(victimValue + 1000) / float(attackerValue + 1000), 0.65, 1.45);
}

void ApplyKillImpact(int attacker, int victim, int assister, float killValue, bool flashAssist, bool traded)
{
	float killerShare = 0.60;
	float damageShare = 0.25;
	float flashShare = flashAssist && assister > 0 && IsTrackingClient(assister) ? 0.10 : 0.0;
	float tradeShare = traded ? 0.10 : 0.0;
	killerShare += 1.0 - (killerShare + damageShare + flashShare + tradeShare);

	AddImpact(attacker, killValue * killerShare);
	DistributeDamageImpact(attacker, victim, killValue * damageShare);
	if (flashShare > 0.0)
	{
		AddImpact(assister, killValue * flashShare);
	}
	if (tradeShare > 0.0)
	{
		AddImpact(attacker, killValue * tradeShare);
		if (IsTrackingClient(g_LastVictim[GetClientTeam(attacker)]))
		{
			AddImpact(g_LastVictim[GetClientTeam(attacker)], killValue * 0.20);
		}
	}

	AddImpact(victim, -killValue * (g_TotalRoundKills == 0 ? 1.15 : 1.0));
}

void DistributeDamageImpact(int killer, int victim, float impact)
{
	int killerTeam = GetClientTeam(killer);
	int totalDamage;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsRoundTrackingClient(client) && GetClientTeam(client) == killerTeam)
		{
			totalDamage += g_RoundDamage[client][victim];
		}
	}

	if (totalDamage <= 0)
	{
		AddImpact(killer, impact);
		return;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsRoundTrackingClient(client) && GetClientTeam(client) == killerTeam && g_RoundDamage[client][victim] > 0)
		{
			AddImpact(client, impact * float(g_RoundDamage[client][victim]) / float(totalDamage));
		}
	}
}

int CountAliveOnTeam(int team)
{
	int count;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsRoundTrackingClient(client) && GetClientTeam(client) == team && IsPlayerAlive(client))
		{
			count++;
		}
	}
	return count;
}

void UpdateClutchCandidates()
{
	UpdateClutchCandidateForTeam(CS_TEAM_T, CS_TEAM_CT);
	UpdateClutchCandidateForTeam(CS_TEAM_CT, CS_TEAM_T);
}

void UpdateClutchCandidateForTeam(int team, int opponentTeam)
{
	int aliveClient;
	int aliveCount;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsRoundTrackingClient(client) && GetClientTeam(client) == team && IsPlayerAlive(client))
		{
			aliveClient = client;
			aliveCount++;
		}
	}

	int opponentAlive = CountAliveOnTeam(opponentTeam);
	if (aliveCount == 1 && opponentAlive >= 2 && aliveClient > 0)
	{
		g_ClutchSize[aliveClient] = MaxInt(g_ClutchSize[aliveClient], opponentAlive);
	}
}

int MaxInt(int first, int second)
{
	return first > second ? first : second;
}

int AbsInt(int value)
{
	return value < 0 ? -value : value;
}

void ResetRoundContext()
{
	g_RoundTracked = false;
	g_TotalRoundKills = 0;
	for (int team = 0; team < 4; team++)
	{
		g_LastDeathTime[team] = 0.0;
		g_LastKiller[team] = 0;
		g_LastVictim[team] = 0;
	}
	for (int client = 1; client <= MaxClients; client++)
	{
		g_RoundParticipant[client] = false;
		g_RoundKills[client] = 0;
		g_RoundDesperationImpact[client] = 0.0;
		g_RoundCleanupImpact[client] = 0.0;
		g_ClutchSize[client] = 0;
		for (int victim = 1; victim <= MaxClients; victim++)
		{
			g_RoundDamage[client][victim] = 0;
		}
	}
}

void ApplyMatchRatingUpdate()
{
	int participants[MAXPLAYERS + 1];
	int participantCount;
	int teamCount[4];
	float teamRating[4];
	int totalRatedMatches;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsTrackingClient(client) || g_MapStats[client][Stat_Rounds] <= 0) continue;
		int team = GetClientTeam(client);
		participants[participantCount++] = client;
		teamCount[team]++;
		teamRating[team] += g_Rating[client];
		totalRatedMatches += g_RatedMatches[client];
	}

	if (teamCount[CS_TEAM_T] == 0 || teamCount[CS_TEAM_CT] == 0)
	{
		return;
	}

	float averageT = teamRating[CS_TEAM_T] / float(teamCount[CS_TEAM_T]);
	float averageCT = teamRating[CS_TEAM_CT] / float(teamCount[CS_TEAM_CT]);
	float expectedT = 1.0 / (1.0 + Pow(10.0, (averageCT - averageT) / 400.0));
	float actualT = GetMatchResultForTeam(CS_TEAM_T);
	int poolSize = teamCount[CS_TEAM_T] < teamCount[CS_TEAM_CT] ? teamCount[CS_TEAM_T] : teamCount[CS_TEAM_CT];
	float kFactor = GetMatchKFactor(totalRatedMatches / participantCount);
	float marginMultiplier = GetScoreMarginMultiplier();
	float tPool = kFactor * marginMultiplier * float(poolSize) * (actualT - expectedT);
	float ctPool = -tPool;

	ApplyRatingPool(CS_TEAM_T, tPool, actualT, participants, participantCount);
	ApplyRatingPool(CS_TEAM_CT, ctPool, 1.0 - actualT, participants, participantCount);
}

float GetMatchResultForTeam(int team)
{
	int tScore = CS_GetTeamScore(CS_TEAM_T);
	int ctScore = CS_GetTeamScore(CS_TEAM_CT);
	if (tScore == ctScore)
	{
		return 0.5;
	}

	if (team == CS_TEAM_T)
	{
		return tScore > ctScore ? 1.0 : 0.0;
	}
	return ctScore > tScore ? 1.0 : 0.0;
}

float GetScoreMarginMultiplier()
{
	int tScore = CS_GetTeamScore(CS_TEAM_T);
	int ctScore = CS_GetTeamScore(CS_TEAM_CT);
	int winningScore = MaxInt(tScore, ctScore);
	if (winningScore <= 0)
	{
		return 1.0;
	}

	float marginRatio = float(AbsInt(tScore - ctScore)) / float(winningScore);
	return 0.75 + ClampFloat(marginRatio, 0.0, 1.0) * 0.50;
}

float GetMatchKFactor(int averageRatedMatches)
{
	if (averageRatedMatches < 10) return 40.0;
	if (averageRatedMatches < 30) return 32.0;
	return 24.0;
}

void ApplyRatingPool(int team, float pool, float result, const int[] participants, int participantCount)
{
	float weightSum;
	float weights[MAXPLAYERS + 1];
	for (int index = 0; index < participantCount; index++)
	{
		int client = participants[index];
		if (GetClientTeam(client) != team) continue;
		float percentile = GetTeamImpactPercentile(client, team, participants, participantCount);
		weights[client] = pool >= 0.0 ? 0.70 + percentile * 0.60 : 1.30 - percentile * 0.60;
		weightSum += weights[client];
	}

	if (weightSum <= 0.0)
	{
		return;
	}

	for (int index = 0; index < participantCount; index++)
	{
		int client = participants[index];
		if (GetClientTeam(client) != team) continue;
		float change = pool * weights[client] / weightSum;
		g_LastRatingChange[client] = change;
		g_Rating[client] = MaxFloat(100.0, g_Rating[client] + change);
		g_PeakRating[client] = MaxFloat(g_PeakRating[client], g_Rating[client]);
		g_RatedMatches[client]++;
		if (result > 0.5) g_RatingWins[client]++;
		else if (result < 0.5) g_RatingLosses[client]++;
	}
}

float GetTeamImpactPercentile(int client, int team, const int[] participants, int participantCount)
{
	int lower;
	int comparable;
	for (int index = 0; index < participantCount; index++)
	{
		int other = participants[index];
		if (other == client || GetClientTeam(other) != team) continue;
		comparable++;
		if (g_MapImpact[other] < g_MapImpact[client])
		{
			lower++;
		}
	}

	if (comparable <= 0)
	{
		return 0.5;
	}
	return float(lower) / float(comparable);
}

void ApplyLeaverPenalty(int client)
{
	g_LastRatingChange[client] = -15.0;
	g_Rating[client] = MaxFloat(100.0, g_Rating[client] - 15.0);
	g_RatedMatches[client]++;
	g_RatingLosses[client]++;
}

int GetMapPosition(int client)
{
	int position = 1;
	float score = g_MapImpact[client];
	for (int other = 1; other <= MaxClients; other++)
	{
		if (other != client && IsHumanClient(other) && g_MapStats[other][Stat_Rounds] > 0 && g_MapImpact[other] > score) position++;
	}
	return position;
}

int GetDatabasePosition(float score)
{
	if (g_Database == null) return 0;
	char query[128];
	Format(query, sizeof(query), "SELECT COUNT(*) FROM rankmaster_ratings WHERE rating > %.3f", score);
	DBResultSet row = SQL_Query(g_Database, query);
	int position = 1;
	if (row != null && row.FetchRow()) position = row.FetchInt(0) + 1;
	delete row;
	return position;
}

void AddStat(int client, Stat stat, int amount)
{
	if (!IsRoundTrackingClient(client)) return;
	g_MapStats[client][stat] += amount;
	g_AllStats[client][stat] += amount;
}

bool ShouldTrack()
{
	return g_RoundTracked;
}

bool CanTrackCurrentRound()
{
	if (g_Finalized) return false;
	if (GameRules_GetProp("m_bWarmupPeriod") != 0) return false;
	if (!g_ForceLive.BoolValue && g_CompetitiveOnly.BoolValue)
	{
		if (g_GameType == null || g_GameMode == null || g_GameType.IntValue != 0 || g_GameMode.IntValue != 1) return false;
	}

	int tPlayers, ctPlayers;
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsHumanClient(client)) continue;
		if (GetClientTeam(client) == CS_TEAM_T) tPlayers++;
		else if (GetClientTeam(client) == CS_TEAM_CT) ctPlayers++;
	}
	return tPlayers >= g_MinTeamPlayers.IntValue && ctPlayers >= g_MinTeamPlayers.IntValue;
}

bool ValidOpponent(int attacker, int victim)
{
	return IsRoundTrackingClient(attacker) && IsRoundTrackingClient(victim) && attacker != victim && GetClientTeam(attacker) != GetClientTeam(victim);
}

bool IsValidAssistClient(int assister, int attacker, int victim)
{
	return IsRoundTrackingClient(assister)
		&& IsRoundTrackingClient(attacker)
		&& IsRoundTrackingClient(victim)
		&& assister != attacker
		&& assister != victim
		&& GetClientTeam(assister) == GetClientTeam(attacker)
		&& GetClientTeam(assister) != GetClientTeam(victim);
}

bool IsTrackingClient(int client)
{
	return IsHumanClient(client) && g_Loaded[client] && (GetClientTeam(client) == CS_TEAM_T || GetClientTeam(client) == CS_TEAM_CT);
}

bool IsRoundTrackingClient(int client)
{
	return client > 0 && client <= MaxClients && g_RoundTracked && g_RoundParticipant[client] && IsTrackingClient(client);
}

bool IsHumanClient(int client)
{
	return client > 0 && client <= MaxClients && IsClientInGame(client) && !IsFakeClient(client);
}

bool RequirePlayer(int client)
{
	if (client <= 0)
	{
		ReplyToCommand(client, "[RankMaster] This command is only available in game.");
		return false;
	}
	if (!g_Loaded[client])
	{
		ReplyToCommand(client, "[RankMaster] Your stats are still loading. Try again in a moment.");
		return false;
	}
	return true;
}

void ResetPlayer(int client)
{
	g_Loaded[client] = false;
	g_Matches[client] = 0;
	g_Rating[client] = 1000.0;
	g_PeakRating[client] = 1000.0;
	g_RatedMatches[client] = 0;
	g_RatingWins[client] = 0;
	g_RatingLosses[client] = 0;
	g_LastRatingChange[client] = 0.0;
	for (int stat = 0; stat < view_as<int>(Stat_Count); stat++) g_AllStats[client][stat] = 0;
	ResetMapStats(client);
}

void ResetMapStats(int client)
{
	g_MapSaved[client] = false;
	g_MapImpact[client] = 0.0;
	g_RoundDesperationImpact[client] = 0.0;
	g_RoundCleanupImpact[client] = 0.0;
	g_RoundKills[client] = 0;
	g_ClutchSize[client] = 0;
	for (int stat = 0; stat < view_as<int>(Stat_Count); stat++) g_MapStats[client][stat] = 0;
	for (int victim = 1; victim <= MaxClients; victim++)
	{
		g_RoundDamage[client][victim] = 0;
		g_RoundDamage[victim][client] = 0;
	}
}

void LogDatabaseError(const char[] operation)
{
	char error[256];
	SQL_GetError(g_Database, error, sizeof(error));
	LogError("Database error while %s: %s", operation, error);
}
