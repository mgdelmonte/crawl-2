/**
 * @file
 * @brief Functions used to print player related info.
**/

#pragma once

#ifdef DGL_SIMPLE_MESSAGING
void update_message_status();
#endif

void reset_hud();

void update_turn_count();

void print_stats();
void print_stats_level();
void draw_border();

// Multiplayer client: pre-computed stats received from host.
struct mp_client_stats
{
    string status_line; // "Waiting on you" / "Waiting on Foo" / etc.
    string title;       // "Foo the Bar"
    string species;     // "Human"
    int hp = 0, hp_max = 0;
    int mp = 0, mp_max = 0;
    int ac = 0, ev = 0, sh = 0;
    int str = 0, intel = 0, dex = 0;
    int xl = 0;
    int turn = 0;
    string place;       // "D:1"
    string weapon;      // weapon name or "Nothing wielded"
    string quiver;      // quiver description
    int noise = 0;      // 0-1000 noise level
    bool silenced = false;
};

// Draw the HUD sidebar using pre-computed stats (for MP clients that
// don't have a fully-initialised player/equipment system).
void mp_client_draw_stats(const mp_client_stats& stats);

// Flash the MP status line briefly (WHITE then restore) to indicate
// the player tried to act but is blocked.
void mp_flash_host_status();
void mp_flash_client_status(const mp_client_stats& stats);

#ifndef USE_TILE_LOCAL
void smallterm_warning();
#endif

void redraw_screen(bool show_updates = true);

string mpr_monster_list(bool past = false);
int update_monster_pane();

int equip_slot_by_name(const char *s);

int stealth_pips();

void print_overview_screen();

string dump_overview_screen();
