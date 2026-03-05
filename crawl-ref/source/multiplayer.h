/**
 * @file
 * @brief Multiplayer state and turn management.
**/

#pragma once

#include "player.h"

struct multiplayer_state
{
    bool enabled = false;
    bool player_has_acted[MAX_PLAYERS] = {};
    bool player_alive[MAX_PLAYERS] = {};
    bool player_connected[MAX_PLAYERS] = {};
    bool player_info_received[MAX_PLAYERS] = {};
    int turn_number = 0;
    int shared_gold = 0;
    bool turn_just_completed = false;  // guard to prevent re-entry
    bool game_started = false;         // true once all players connected & ready

    // Returns true if all living players have acted this turn.
    bool all_acted() const;

    // Returns true if all remote players have connected.
    bool all_connected() const;

    // Returns true if all remote players have sent player_info.
    bool all_info_received() const;

    // Reset acted flags for a new turn.
    void reset_turn();

    // Count how many players are currently alive.
    int count_alive() const;

    // Initialize multiplayer state for the given number of players.
    void init(int num_pl);
};

extern multiplayer_state mp_state;

// Returns true if the given actor is a player allied with the active player.
// In multiplayer, all players are allies (no PvP).
bool is_allied_player(const actor *act);
