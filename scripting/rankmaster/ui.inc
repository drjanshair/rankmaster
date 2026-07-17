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
