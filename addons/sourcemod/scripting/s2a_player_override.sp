#pragma newdecls required
#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <dhooks>


public Plugin myinfo =
{
  name        = "[S2A_PLAYER] Override",
  author      = "TouchMe", // Poggu (ver. csgo)
  description = "Add team tags in S2A_PLAYER response (server browser query)",
  version     = "build_0002"
};


/**
 * NET_SendPacket(netchan, socket, address, data, length)
 */
#define SIG_NET_SEND_PACKET     "NET_SendPacket" 

/**
 * Gamedata file containing signatures/offsets for this plugin
 */
#define GAMEDATA_FILE           "s2a_player_override.games"

/**
 * Teams.
 */
#define TEAM_SPECTATOR          1
#define TEAM_SURVIVOR           2
#define TEAM_INFECTED           3

/**
 * Cache lifetime for S2A_PLAYER response (seconds)
 */
#define CACHE_TTL               1.0

/**
 * Maximum buffer size for packet data (bytes)
 */
#define MAXSIZE_DATA            2048


enum
{
    ARG_Netchan = 1,
    ARG_Socket,
    ARG_Address,
    ARG_Data,
    ARG_Length
};

int S2A_PLAYER_HEADER[] = { 0xFF, 0xFF, 0xFF, 0xFF, 0x44 };


/**
 * Plugin entry point — sets up a detour on NET_SendPacket.
 */
public void OnPluginStart()
{
    GameData hGameConf = LoadGameConfigFile(GAMEDATA_FILE);
    if (!hGameConf)
    {
        SetFailState("Missing gamedata: \"" ... GAMEDATA_FILE ... "\"");
    }

    Handle hNetSendPacket = SetupNetSendPacketDetour(hGameConf);

    RegisterNetSendPacketParams(hNetSendPacket);

    if (!DHookEnableDetour(hNetSendPacket, false, Detour_OnNetSendPacket))
    {
        SetFailState("Failed to detour NET_SendPacket.");
    }

    delete hGameConf;
}

/**
 * Resolves NET_SendPacket from gamedata and creates the detour handle.
 */
Handle SetupNetSendPacketDetour(GameData hGameConf)
{
    Address addrSendPacket = hGameConf.GetMemSig(SIG_NET_SEND_PACKET);
    if (addrSendPacket == Address_Null) {
        SetFailState(SIG_NET_SEND_PACKET ... ": signature not found in engine.[dll|so].");
    }

    Handle hDetour = DHookCreateDetour(addrSendPacket, CallConv_CDECL, ReturnType_Int, ThisPointer_Ignore);
    if (!hDetour) {
        SetFailState("DHookCreateDetour: Failed to create detour for " ... SIG_NET_SEND_PACKET);
    }

    if (!DHookSetFromConf(hDetour, hGameConf, SDKConf_Signature, SIG_NET_SEND_PACKET)) {
        SetFailState("DHookSetFromConf: Signature found but setup may be incompatible for " ... SIG_NET_SEND_PACKET);
    }

    return hDetour;
}

/**
 * Registers parameters for NET_SendPacket.
 * Keep types meaningful, even if you don't use them all.
 */
void RegisterNetSendPacketParams(Handle hDetour)
{
    HookParamType PARAMS[] =
    {
        HookParamType_Int, // arg1
        HookParamType_Int, // arg2
        HookParamType_Int, // arg3
        HookParamType_Int, // arg4
        HookParamType_Int  // arg5
    };

    for (int i = 0; i < sizeof(PARAMS); i++)
    {
        DHookAddParam(hDetour, PARAMS[i]);
    }
}

/**
 * Detours NET_SendPacket and overrides outgoing S2A_PLAYER responses with a cached/custom-built payload.
 *
 * Behavior:
 *  - Validates the outgoing payload starts with S2A_PLAYER header.
 *  - Rebuilds and caches the full response on TTL expiry; otherwise reuses the cached bytes.
 *  - Overwrites the packet data in-place and adjusts the length parameter.
 *
 * Caching:
 *  - Uses a static byte buffer (szCachedResponse) with a TTL (CACHE_TTL).
 *  - Rebuild occurs on first hit or when TTL has elapsed.
 *
 * Assumptions:
 *  - The cached response fits into the outgoing buffer region (no explicit truncation here).
 *  - The header constant S2A_PLAYER_HEADER matches the protocol (0xFF 0xFF 0xFF 0xFF 0x44).
 *
 * @param hReturn   DHooks return handle (unused)
 * @param hParams   DHooks params handle (used to read/write packet arguments)
 * @return          MRES_ChangedHandled when packet is overridden; MRES_Ignored otherwise
 */
public MRESReturn Detour_OnNetSendPacket(Handle hReturn, Handle hParams)
{
    static char szCachedResponse[MAXSIZE_DATA];
    static int iCachedLength;
    static float fLastBuildTime;

    Address pData = DHookGetParam(hParams, ARG_Data);
    int iPacketLength = DHookGetParam(hParams, ARG_Length);

    // Quick length guard before header check
    if (iPacketLength < sizeof(S2A_PLAYER_HEADER)) {
        return MRES_Ignored;
    }

    // Verify the outgoing data matches S2A_PLAYER header
    if (!IsA2SPlayerRequest(pData)) {
        return MRES_Ignored;
    }

    // TTL-based cache refresh
    float fCurrentTime = GetEngineTime();
    if (fCurrentTime - fLastBuildTime > CACHE_TTL)
    {
        iCachedLength = BuildResponse(szCachedResponse, sizeof(szCachedResponse));
        fLastBuildTime = fCurrentTime;
    }

    // Overwrite outgoing bytes with cached payload
    for (int i = 0; i < iCachedLength; i++)
    {
        StoreToAddress(pData + view_as<Address>(i), szCachedResponse[i], NumberType_Int8);
    }

    // Update length to match cached payload
    DHookSetParam(hParams, ARG_Length, iCachedLength);

    return MRES_ChangedHandled;
}


/**
 * Checks whether the memory at the given address begins with the S2A_PLAYER header.
 *
 * Note:
 *  - Despite the name, this function validates an S2A (Server-to-Application) response header,
 *    not an A2S request. Consider renaming to IsS2APlayerHeader for clarity.
 *
 * @param address   Pointer to the start of packet data
 * @return          true if data matches S2A_PLAYER header; false otherwise
 */
bool IsA2SPlayerRequest(Address address)
{
    for (int i = 0; i < sizeof(S2A_PLAYER_HEADER); i++)
    {
        if (S2A_PLAYER_HEADER[i] != LoadFromAddress(address + view_as<Address>(i), NumberType_Int8)) {
            return false;
        }
    }
    return true;
}

/**
 * Builds a complete S2A_PLAYER response into the provided buffer.
 *
 * Layout:
 *  - Header: 0xFF 0xFF 0xFF 0xFF 0x44
 *  - Count (1 byte): number of player entries
 *  - Repeated per player:
 *      * Index (1 byte)
 *      * Name (cstring, null-terminated)
 *      * Score (int32, little-endian)
 *      * Time (float32 as bytes, little-endian)
 *
 * Buffer safety:
 *  - Uses Append* helpers that hard-cap writes at iMaxLen.
 *  - If capacity is exceeded mid-entry, data may be truncated (no rollback).
 *
 * @param szOut     Output buffer receiving the serialized packet
 * @param iMaxLen   Maximum capacity of szOut in bytes
 * @return          Number of bytes written into szOut
 */
int BuildResponse(char[] szOut, int iMaxLen)
{
    int iPos = 0;
    int iPlayerCount = 0;

    // Header
    AppendData(szOut, iMaxLen, iPos, S2A_PLAYER_HEADER, sizeof(S2A_PLAYER_HEADER));

    // Placeholder for player count (patched after players are written)
    int iCountOffset = iPos;
    AppendByte(szOut, iMaxLen, iPos, iPlayerCount);

    // Players
    char szName[MAX_NAME_LENGTH];
    for (int iPlayer = 1; iPlayer <= MaxClients; iPlayer++)
    {
        if (!IsClientInGame(iPlayer) || IsFakeClient(iPlayer)) {
            continue;
        }

        switch (GetClientTeam(iPlayer))
        {
            case TEAM_INFECTED: FormatEx(szName, sizeof(szName),  "SI   : %N", iPlayer);
            case TEAM_SURVIVOR: FormatEx(szName, sizeof(szName),  "S    : %N", iPlayer);
            case TEAM_SPECTATOR: FormatEx(szName, sizeof(szName), "SPEC : %N", iPlayer);
            default: FormatEx(szName, sizeof(szName),             "?    : %N", iPlayer);
        }

        AppendByte(szOut, iMaxLen, iPos, iPlayerCount++);
        AppendCString(szOut, iMaxLen, iPos, szName);
        AppendLE32(szOut, iMaxLen, iPos, GetClientFrags(iPlayer));
        AppendLE32(szOut, iMaxLen, iPos, view_as<int>(GetClientTime(iPlayer)));
    }

    // Patch the count byte
    szOut[iCountOffset] = iPlayerCount;

    return iPos;
}

/**
 * Appends a single byte to the buffer.
 *
 * @param szBuf      Destination buffer
 * @param iMaxLen    Maximum buffer length
 * @param iPos       Current write position (updated by reference)
 * @param iValue     Byte value to append (only low 8 bits are used)
 */
void AppendByte(char[] szBuf, int iMaxLen, int &iPos, int iValue)
{
    if (iPos < iMaxLen) {
        szBuf[iPos++] = iValue;
    }
}

/**
 * Appends a 32-bit integer in Little Endian format.
 *
 * @param szBuf      Destination buffer
 * @param iMaxLen    Maximum buffer length
 * @param iPos       Current write position (updated by reference)
 * @param iValue     Integer value to append
 */
void AppendLE32(char[] szBuf, int iMaxLen, int &iPos, int iValue)
{
    AppendByte(szBuf, iMaxLen, iPos,  iValue       );
    AppendByte(szBuf, iMaxLen, iPos, (iValue >> 8) );
    AppendByte(szBuf, iMaxLen, iPos, (iValue >> 16));
    AppendByte(szBuf, iMaxLen, iPos, (iValue >> 24));
}

/**
 * Appends a C-style null-terminated string.
 *
 * @param szBuf      Destination buffer
 * @param iMaxLen    Maximum buffer length
 * @param iPos       Current write position (updated by reference)
 * @param szText     String to append (null-terminated)
 */
void AppendCString(char[] szBuf, int iMaxLen, int &iPos, const char[] szText)
{
    int iLen = strlen(szText);

    for (int i = 0; i < iLen; i++)
    {
        AppendByte(szBuf, iMaxLen, iPos, szText[i]);
    }

    // Append null terminator
    AppendByte(szBuf, iMaxLen, iPos, 0x00);
}

/**
 * Appends an arbitrary block of raw bytes to the buffer.
 *
 * @param szBuf      Destination buffer
 * @param iMaxLen    Maximum buffer length
 * @param iPos       Current write position (updated by reference)
 * @param szData     Source data array
 * @param iDataLen   Number of bytes to append
 */
void AppendData(char[] szBuf, int iMaxLen, int &iPos, const any[] szData, int iDataLen)
{
    for (int i = 0; i < iDataLen && iPos < iMaxLen; i++)
    {
        szBuf[iPos++] = szData[i];
    }
}
