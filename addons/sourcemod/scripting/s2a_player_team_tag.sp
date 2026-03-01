#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>

forward Action S2A_OnPreparePlayerInfo(int iClient, char[] szName, int iLength, int &iScore, int &iConnectTime);


public Plugin myinfo = {
    name        = "[S2A_PLAYER] Override",
    author      = "TouchMe", // Poggu (ver. csgo)
    description = "Add team tags in S2A_PLAYER response (server browser query)",
    version     = "build_0003",
    url         = "https://github.com/TouchMe-Inc/s2a_player_override"
};


/**
 * Teams.
 */
#define TEAM_SPECTATOR          1
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3


public Action S2A_OnPreparePlayerInfo(int iClient, char[] szName, int iLength, int &iScore, int &iConnectTime)
{
    if (!IsClientInGame(iClient))
    {
        Format(szName, iLength,  "JOIN : %N", iClient);
        return Plugin_Continue;
    }

    switch (GetClientTeam(iClient))
    {
        case TEAM_INFECTED: Format(szName, iLength,  "SI   : %N", iClient);
        case TEAM_SURVIVOR: Format(szName, iLength,  "S    : %N", iClient);
        case TEAM_SPECTATOR: Format(szName, iLength, "SPEC : %N", iClient);
        default: Format(szName, iLength,             "?    : %N", iClient);
    }

    return Plugin_Continue;
}