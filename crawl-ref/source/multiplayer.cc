/**
 * @file
 * @brief Multiplayer state and turn management.
**/

#include "AppHdr.h"

#include "multiplayer.h"

multiplayer_state mp_state;

bool multiplayer_state::all_acted() const
{
    for (int i = 0; i < num_players; i++)
        if (player_alive[i] && !player_has_acted[i])
            return false;
    return true;
}

void multiplayer_state::reset_turn()
{
    for (int i = 0; i < MAX_PLAYERS; i++)
        player_has_acted[i] = false;
    turn_number++;
}

int multiplayer_state::count_alive() const
{
    int count = 0;
    for (int i = 0; i < num_players; i++)
        if (player_alive[i])
            count++;
    return count;
}

void multiplayer_state::init(int num_pl)
{
    enabled = (num_pl > 1);
    turn_number = 0;
    shared_gold = 0;
    game_started = false;
    for (int i = 0; i < MAX_PLAYERS; i++)
    {
        player_has_acted[i] = false;
        player_alive[i] = (i < num_pl);
        player_connected[i] = false;
        player_info_received[i] = false;
    }
    // Host (player 0) is always connected and has info.
    player_connected[0] = true;
    player_info_received[0] = true;

    // Set player indices.
    for (int i = 0; i < num_pl; i++)
        players[i].player_index = i;
}

bool multiplayer_state::all_connected() const
{
    for (int i = 0; i < num_players; i++)
        if (!player_connected[i])
            return false;
    return true;
}

bool multiplayer_state::all_info_received() const
{
    for (int i = 0; i < num_players; i++)
        if (!player_info_received[i])
            return false;
    return true;
}

bool is_allied_player(const actor *act)
{
    if (!mp_state.enabled || !act || !act->is_player())
        return false;

    // In multiplayer, all players are allies (co-op, no PvP).
    const player *pl = act->as_player();
    return pl->player_index != active_player_idx;
}
