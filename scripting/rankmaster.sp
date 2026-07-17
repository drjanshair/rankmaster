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

const float LOW_SIGNAL_IMPACT_SHARE = 0.50;
const float LOW_SIGNAL_CLAWBACK = 0.75;

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
		int attackerAlive = CountAliveOnTeam(attackerTeam);
		int victimAliveBefore = CountAliveOnTeam(victimTeam) + 1;
		bool traded = g_LastKiller[attackerTeam] == victim && GetGameTime() - g_LastDeathTime[attackerTeam] <= 5.0;
		float killValue = CalculateKillValue(attacker, victim, headshot);
		ApplyKillImpact(attacker, victim, validAssister ? assister : 0, killValue, validFlashAssist, traded);

		if (attackerAlive == 1 && victimAliveBefore >= 3)
		{
			g_RoundDesperationImpact[attacker] += killValue * LOW_SIGNAL_IMPACT_SHARE;
		}

		if (attackerAlive >= 3 && victimAliveBefore == 1)
		{
			g_RoundCleanupImpact[attacker] += killValue * LOW_SIGNAL_IMPACT_SHARE;
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
			AddImpact(client, -g_RoundDesperationImpact[client] * LOW_SIGNAL_CLAWBACK);
		}
		if (GetClientTeam(client) == winner && g_RoundCleanupImpact[client] > 0.0)
		{
			AddImpact(client, -g_RoundCleanupImpact[client] * LOW_SIGNAL_CLAWBACK);
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

void AddStat(int client, Stat stat, int amount)
{
	if (!IsRoundTrackingClient(client)) return;
	g_MapStats[client][stat] += amount;
	g_AllStats[client][stat] += amount;
}

bool ShouldTrack()
{
	return g_RoundTracked && !g_Finalized;
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

#include "rankmaster/persistence.inc"
#include "rankmaster/impact.inc"
#include "rankmaster/rating.inc"
#include "rankmaster/ui.inc"
