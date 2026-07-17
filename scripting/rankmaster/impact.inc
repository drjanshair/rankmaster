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
	float flashShare = flashAssist && IsRoundTrackingClient(assister) ? 0.10 : 0.0;
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
		if (IsRoundTrackingClient(g_LastVictim[GetClientTeam(attacker)]))
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
		g_RoundTeam[client] = 0;
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
