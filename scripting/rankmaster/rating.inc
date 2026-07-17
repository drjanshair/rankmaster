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
	float marginMultiplier = GetMatchMarginMultiplier();
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

float GetMatchMarginMultiplier()
{
	int tScore = CS_GetTeamScore(CS_TEAM_T);
	int ctScore = CS_GetTeamScore(CS_TEAM_CT);
	if (tScore == ctScore)
	{
		return 1.0;
	}

	int winnerScore = tScore > ctScore ? tScore : ctScore;
	int scoreDifference = tScore > ctScore ? tScore - ctScore : ctScore - tScore;
	if (winnerScore <= 0)
	{
		return 1.0;
	}

	float marginRatio = float(scoreDifference) / float(winnerScore);
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
