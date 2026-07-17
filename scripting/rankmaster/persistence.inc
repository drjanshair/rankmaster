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

void LogDatabaseError(const char[] operation)
{
	char error[256];
	SQL_GetError(g_Database, error, sizeof(error));
	LogError("Database error while %s: %s", operation, error);
}
