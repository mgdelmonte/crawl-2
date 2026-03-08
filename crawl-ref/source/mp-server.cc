/**
 * @file
 * @brief Multiplayer TCP server (host side).
**/

// Winsock2 must be included before AppHdr.h to prevent windows.h macro
// conflicts (PURE, NEAR, etc.) — AppHdr.h will redefine them correctly.
#ifdef _WIN32
# define WIN32_LEAN_AND_MEAN
# define NOMINMAX
# ifndef _WIN32_WINNT
#  define _WIN32_WINNT 0x0600
# endif
# include <winsock2.h>
# include <ws2tcpip.h>
#endif

#include "AppHdr.h"

#include "mp-server.h"

#include <cerrno>
#include <cstring>
#ifdef TARGET_OS_WINDOWS
# define poll WSAPoll
# define close closesocket
# define SHUT_RDWR SD_BOTH
  static inline int mp_socket_errno() { return WSAGetLastError(); }
  static inline bool mp_would_block()
  { int e = WSAGetLastError(); return e == WSAEWOULDBLOCK || e == WSAEINTR; }
#else
  static inline int mp_socket_errno() { return errno; }
  static inline bool mp_would_block()
  { return errno == EAGAIN || errno == EWOULDBLOCK; }
# include <sys/socket.h>
# include <sys/types.h>
# include <netinet/in.h>
# include <arpa/inet.h>
# include <unistd.h>
# include <fcntl.h>
# include <poll.h>
#endif

#include "json.h"
#include "json-wrapper.h"
#include "areas.h"
#include "branch.h"
#include "description-level-type.h"
#include "item-name.h"
#include "jobs.h"
#include "message.h"
#include "quiver.h"
#include "stringutil.h"
#include "multiplayer.h"
#include "player.h"
#include "player-stats.h"
#include "skills.h"
#include "species.h"
#include "state.h"
#include "env.h"
#include "items.h"
#include "mon-info.h"

MPServer mp_server;

static void set_nonblocking(int fd)
{
#ifdef TARGET_OS_WINDOWS
    u_long mode = 1;
    ioctlsocket(fd, FIONBIO, &mode);
#else
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
#endif
}

MPServer::MPServer()
{
}

MPServer::~MPServer()
{
    stop();
}

bool MPServer::start(int port, int expected_players)
{
    m_expected_players = expected_players;

#ifdef TARGET_OS_WINDOWS
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
#endif

    m_listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (m_listen_fd < 0)
    {
        m_last_error = make_stringf("failed to create socket: %s",
                                    strerror(errno));
        mprf(MSGCH_ERROR, "MP server: %s", m_last_error.c_str());
        return false;
    }

    // Allow address reuse.
    int opt = 1;
    setsockopt(m_listen_fd, SOL_SOCKET, SO_REUSEADDR,
               reinterpret_cast<const char*>(&opt), sizeof(opt));

    sockaddr_in addr = {};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (::bind(m_listen_fd, (sockaddr*)&addr, sizeof(addr)) < 0)
    {
        m_last_error = make_stringf("failed to bind port %d: %s",
                                    port, strerror(errno));
        mprf(MSGCH_ERROR, "MP server: %s", m_last_error.c_str());
        close(m_listen_fd);
        m_listen_fd = -1;
        return false;
    }

    if (listen(m_listen_fd, 4) < 0)
    {
        m_last_error = make_stringf("listen failed: %s", strerror(errno));
        mprf(MSGCH_ERROR, "MP server: %s", m_last_error.c_str());
        close(m_listen_fd);
        m_listen_fd = -1;
        return false;
    }

    set_nonblocking(m_listen_fd);
    m_running = true;

    // Reserve space for client connections (players 1..N-1).
    m_clients.resize(expected_players - 1);
    for (int i = 0; i < expected_players - 1; i++)
        m_clients[i].player_idx = i + 1;

    mprf(MSGCH_PLAIN, "MP server: listening on port %d, waiting for %d player(s)...",
         port, expected_players - 1);

    return true;
}

void MPServer::stop()
{
    for (auto& client : m_clients)
    {
        if (client.socket_fd >= 0)
        {
            close(client.socket_fd);
            client.socket_fd = -1;
            client.connected = false;
        }
    }
    m_clients.clear();

    if (m_listen_fd >= 0)
    {
        close(m_listen_fd);
        m_listen_fd = -1;
    }
    m_running = false;
}

bool MPServer::try_accept_connection(bool& error_out, int poll_timeout_ms)
{
    error_out = false;

    if (!m_running || m_listen_fd < 0)
        return false;

    struct pollfd pfd;
    pfd.fd = m_listen_fd;
    pfd.events = POLLIN;
    pfd.revents = 0;

    int ret = poll(&pfd, 1, poll_timeout_ms);
    if (ret < 0)
    {
        if (mp_would_block())
            return false;
        mprf(MSGCH_ERROR, "MP server: poll error (%d)", mp_socket_errno());
        error_out = true;
        return false;
    }

    if (ret == 0 || !(pfd.revents & POLLIN))
        return false;

    sockaddr_in client_addr = {};
    socklen_t client_len = sizeof(client_addr);
    int client_fd = accept(m_listen_fd,
                           (sockaddr*)&client_addr, &client_len);
    if (client_fd < 0)
    {
        if (mp_would_block())
            return false;
        mprf(MSGCH_ERROR, "MP server: accept error (%d)", mp_socket_errno());
        return false;
    }

    set_nonblocking(client_fd);

    int connected_count = num_connected();
    int needed = m_expected_players - 1;

    if (connected_count < (int)m_clients.size())
    {
        auto& slot = m_clients[connected_count];
        slot.socket_fd = client_fd;
        slot.connected = true;
        connected_count++;

        // Send welcome message with assigned player index.
        JsonNode *welcome = json_mkobject();
        json_append_member(welcome, "type",
                           json_mkstring("welcome"));
        json_append_member(welcome, "player_idx",
                           json_mknumber(slot.player_idx));
        json_append_member(welcome, "num_players",
                           json_mknumber(m_expected_players));
        char *msg = json_encode(welcome);
        string welcome_msg = string(msg) + "\n";
        free(msg);
        json_delete(welcome);

        send(client_fd, welcome_msg.c_str(),
             welcome_msg.size(), 0);

        mprf(MSGCH_PLAIN,
             "MP server: player %d connected (%d/%d).",
             slot.player_idx, connected_count, needed);

        return true;
    }
    else
    {
        // Too many connections; reject.
        close(client_fd);
        return false;
    }
}

bool MPServer::all_connected() const
{
    return num_connected() >= m_expected_players - 1;
}

bool MPServer::wait_for_connections()
{
    // Legacy blocking version — prefer using try_accept_connection()
    // in a loop with UI pumping instead.
    while (!all_connected())
    {
        bool error = false;
        try_accept_connection(error);
        if (error)
            return false;
#ifdef TARGET_OS_WINDOWS
        _sleep(50); // 50ms
#else
        usleep(50000); // 50ms
#endif
    }

    mprf(MSGCH_PLAIN, "MP server: all %d players connected!",
         m_expected_players - 1);
    return true;
}

vector<pair<int, string>> MPServer::poll_commands()
{
    vector<pair<int, string>> commands;

    if (!m_running)
        return commands;

    // Build poll set for all connected clients.
    vector<struct pollfd> pfds;
    vector<int> client_indices;

    for (int i = 0; i < (int)m_clients.size(); i++)
    {
        if (m_clients[i].connected && m_clients[i].socket_fd >= 0)
        {
            struct pollfd pfd;
            pfd.fd = m_clients[i].socket_fd;
            pfd.events = POLLIN;
            pfd.revents = 0;
            pfds.push_back(pfd);
            client_indices.push_back(i);
        }
    }

    if (pfds.empty())
        return commands;

    int ret = poll(pfds.data(), pfds.size(), 0); // non-blocking
    if (ret <= 0)
        return commands;

    for (int i = 0; i < (int)pfds.size(); i++)
    {
        if (pfds[i].revents & POLLIN)
        {
            auto& client = m_clients[client_indices[i]];
            auto msgs = read_messages(client);
            for (auto& msg : msgs)
                commands.emplace_back(client.player_idx, msg);
        }
        if (pfds[i].revents & (POLLERR | POLLHUP))
        {
            auto& client = m_clients[client_indices[i]];
            mprf(MSGCH_ERROR, "MP server: player %d disconnected.",
                 client.player_idx);
            close(client.socket_fd);
            client.socket_fd = -1;
            client.connected = false;
        }
    }

    return commands;
}

void MPServer::send_to(int player_idx, const string& json_msg)
{
    for (auto& client : m_clients)
    {
        if (client.player_idx == player_idx && client.connected)
        {
            string line = json_msg + "\n";
            send(client.socket_fd, line.c_str(), line.size(), 0);
            return;
        }
    }
}

void MPServer::broadcast(const string& json_msg)
{
    string line = json_msg + "\n";
    for (auto& client : m_clients)
    {
        if (client.connected)
            send(client.socket_fd, line.c_str(), line.size(), 0);
    }
}

void MPServer::broadcast_game_state()
{
    // Build a JSON game state object with all player info and map data.
    JsonNode *state = json_mkobject();
    json_append_member(state, "type", json_mkstring("game_state"));
    json_append_member(state, "turn", json_mknumber(mp_state.turn_number));

    // Player data array.
    JsonNode *player_arr = json_mkarray();
    for (int i = 0; i < num_players; i++)
    {
        JsonNode *pdata = json_mkobject();
        json_append_member(pdata, "idx", json_mknumber(i));
        json_append_member(pdata, "name",
                           json_mkstring(players[i].your_name.c_str()));
        json_append_member(pdata, "alive",
                           json_mkbool(mp_state.player_alive[i]));
        json_append_member(pdata, "hp",
                           json_mknumber(players[i].hp));
        json_append_member(pdata, "hp_max",
                           json_mknumber(players[i].hp_max));
        json_append_member(pdata, "mp",
                           json_mknumber(players[i].magic_points));
        json_append_member(pdata, "mp_max",
                           json_mknumber(players[i].max_magic_points));
        json_append_member(pdata, "x",
                           json_mknumber(players[i].pos().x));
        json_append_member(pdata, "y",
                           json_mknumber(players[i].pos().y));
        json_append_member(pdata, "acted",
                           json_mkbool(mp_state.player_has_acted[i]));

        // Stats for display: use computed values from the host player
        // (player 0, where `you` is valid) or base values for others.
        if (i == 0)
        {
            json_append_member(pdata, "ac",
                               json_mknumber(you.armour_class_scaled(1)));
            json_append_member(pdata, "ev",
                               json_mknumber(you.evasion_scaled(1)));
            json_append_member(pdata, "sh",
                               json_mknumber(player_displayed_shield_class()));
        }
        else
        {
            // Remote players: use base AC/EV from their player struct.
            json_append_member(pdata, "ac",
                               json_mknumber(players[i].base_ac(1)));
            json_append_member(pdata, "ev",
                               json_mknumber(10)); // base EV
            json_append_member(pdata, "sh",
                               json_mknumber(0));
        }
        json_append_member(pdata, "str",
                           json_mknumber(players[i].base_stats[STAT_STR]));
        json_append_member(pdata, "intel",
                           json_mknumber(players[i].base_stats[STAT_INT]));
        json_append_member(pdata, "dex",
                           json_mknumber(players[i].base_stats[STAT_DEX]));
        json_append_member(pdata, "xl",
                           json_mknumber(players[i].experience_level));
        json_append_member(pdata, "species_name",
                           json_mkstring(
                               species::name(players[i].species).c_str()));

        // Title: for host player, use proper computed title;
        // for others, construct from job name.
        if (i == 0)
        {
            string title = players[i].your_name + " the "
                           + player_title(false);
            json_append_member(pdata, "title",
                               json_mkstring(title.c_str()));
        }
        else
        {
            string title = players[i].your_name + " the "
                           + get_job_name(players[i].char_class);
            json_append_member(pdata, "title",
                               json_mkstring(title.c_str()));
        }

        // Weapon name.
        if (i == 0)
        {
            const item_def *weapon = you.weapon();
            string wpn_name;
            if (weapon)
                wpn_name = weapon->name(DESC_PLAIN, true);
            else
                wpn_name = you.unarmed_attack_name();
            json_append_member(pdata, "weapon",
                               json_mkstring(wpn_name.c_str()));
        }
        else
        {
            json_append_member(pdata, "weapon",
                               json_mkstring(""));
        }

        // Quiver description (host player only).
        if (i == 0)
        {
            string qv = quiver::get_secondary_action()
                             ->quiver_description().tostring();
            json_append_member(pdata, "quiver",
                               json_mkstring(qv.c_str()));
        }
        else
        {
            json_append_member(pdata, "quiver",
                               json_mkstring(""));
        }

        // Noise level and silence.
        if (i == 0)
        {
            bool sil = silenced(you.pos());
            int noise = sil ? 0 : you.get_noise_perception(true);
            json_append_member(pdata, "noise",
                               json_mknumber(noise));
            json_append_member(pdata, "silenced",
                               json_mkbool(sil));
        }
        else
        {
            json_append_member(pdata, "noise", json_mknumber(0));
            json_append_member(pdata, "silenced", json_mkbool(false));
        }

        json_append_element(player_arr, pdata);
    }
    json_append_member(state, "players", player_arr);

    json_append_member(state, "shared_gold",
                       json_mknumber(mp_state.shared_gold));

    // Messages are now sent per-player via "messages" type, not broadcast.

    // Ground items: send all items on the floor so clients can render them.
    {
        JsonNode *items_arr = json_mkarray();
        for (int i = 0; i < MAX_ITEMS; i++)
        {
            const item_def& item = env.item[i];
            if (!item.defined() || !in_bounds(item.pos))
                continue;
            // Skip items in player/monster inventory (pos -1,-1 or -2,-2).
            if (item.pos.x < 0)
                continue;

            JsonNode *idata = json_mkobject();
            json_append_member(idata, "x", json_mknumber(item.pos.x));
            json_append_member(idata, "y", json_mknumber(item.pos.y));
            json_append_member(idata, "base_type",
                               json_mknumber((int)item.base_type));
            json_append_member(idata, "sub_type",
                               json_mknumber(item.sub_type));
            json_append_member(idata, "quantity",
                               json_mknumber(item.quantity));
            json_append_member(idata, "colour",
                               json_mknumber(item.get_colour()));
            json_append_member(idata, "rnd",
                               json_mknumber(item.rnd));
            json_append_member(idata, "plus",
                               json_mknumber(item.plus));
            json_append_member(idata, "special",
                               json_mknumber(item.special));
            json_append_element(items_arr, idata);
        }
        json_append_member(state, "items", items_arr);
    }

    // Monsters: send visible monster data so clients can render them.
    {
        JsonNode *mons_arr = json_mkarray();
        for (int i = 0; i < MAX_MONSTERS; i++)
        {
            const monster& mons = env.mons[i];
            if (!mons.alive() || !in_bounds(mons.pos()))
                continue;

            JsonNode *mdata = json_mkobject();
            json_append_member(mdata, "x", json_mknumber(mons.pos().x));
            json_append_member(mdata, "y", json_mknumber(mons.pos().y));
            json_append_member(mdata, "type",
                               json_mknumber((int)mons.type));
            json_append_member(mdata, "attitude",
                               json_mknumber((int)mons.attitude));
            json_append_member(mdata, "hd",
                               json_mknumber(mons.get_hit_dice()));

            // Send the name and base type for display.
            json_append_member(mdata, "name",
                               json_mkstring(mons.name(DESC_PLAIN).c_str()));
            json_append_member(mdata, "base_type",
                               json_mknumber((int)mons.base_monster));

            json_append_element(mons_arr, mdata);
        }
        json_append_member(state, "monsters", mons_arr);
    }

    // Current place (all players are on the same level).
    {
        string place = branches[you.where_are_you].shortname;
        if (brdepth[you.where_are_you] > 1)
            place += make_stringf(":%d", you.depth);
        json_append_member(state, "place", json_mkstring(place.c_str()));
    }

    char *encoded = json_encode(state);
    string msg(encoded);
    free(encoded);
    json_delete(state);

    broadcast(msg);
}

void MPServer::send_turn_start(int player_idx, int turn)
{
    JsonNode *msg = json_mkobject();
    json_append_member(msg, "type", json_mkstring("turn_start"));
    json_append_member(msg, "turn", json_mknumber(turn));

    char *encoded = json_encode(msg);
    send_to(player_idx, string(encoded));
    free(encoded);
    json_delete(msg);
}

void MPServer::broadcast_level_data()
{
    JsonNode *msg = json_mkobject();
    json_append_member(msg, "type", json_mkstring("level_data"));
    json_append_member(msg, "gxm", json_mknumber(GXM));
    json_append_member(msg, "gym", json_mknumber(GYM));

    JsonNode *grid_arr = json_mkarray();
    for (int y = 0; y < GYM; y++)
        for (int x = 0; x < GXM; x++)
            json_append_element(grid_arr, json_mknumber((int)env.grid[x][y]));
    json_append_member(msg, "grid", grid_arr);

    char *encoded = json_encode(msg);
    broadcast(string(encoded));
    free(encoded);
    json_delete(msg);
}

int MPServer::num_connected() const
{
    int count = 0;
    for (auto& client : m_clients)
        if (client.connected)
            count++;
    return count;
}

bool MPServer::is_player_connected(int player_idx) const
{
    for (auto& client : m_clients)
        if (client.connected && client.player_idx == player_idx)
            return true;
    return false;
}

vector<string> MPServer::read_messages(mp_client_conn& client)
{
    vector<string> messages;

    char buf[4096];
    ssize_t n = recv(client.socket_fd, buf, sizeof(buf), 0);
    if (n <= 0)
    {
        if (n == 0 || !mp_would_block())
        {
            // Connection closed or error.
            client.connected = false;
            close(client.socket_fd);
            client.socket_fd = -1;
        }
        return messages;
    }

    client.recv_buffer.append(buf, n);

    // Extract complete newline-delimited messages.
    size_t pos;
    while ((pos = client.recv_buffer.find('\n')) != string::npos)
    {
        string line = client.recv_buffer.substr(0, pos);
        client.recv_buffer.erase(0, pos + 1);
        if (!line.empty())
            messages.push_back(line);
    }

    return messages;
}
