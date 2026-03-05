/**
 * @file
 * @brief Multiplayer TCP server (host side).
**/

#include "AppHdr.h"

#include "mp-server.h"

#include <cerrno>
#include <cstring>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>

#include "json.h"
#include "json-wrapper.h"
#include "message.h"
#include "stringutil.h"
#include "multiplayer.h"
#include "player.h"
#include "state.h"
#include "env.h"

MPServer mp_server;

static void set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
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
    setsockopt(m_listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

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
        if (errno == EINTR)
            return false;
        mprf(MSGCH_ERROR, "MP server: poll error: %s", strerror(errno));
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
        if (errno == EAGAIN || errno == EWOULDBLOCK)
            return false;
        mprf(MSGCH_ERROR, "MP server: accept error: %s", strerror(errno));
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
        usleep(50000); // 50ms
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
        json_append_element(player_arr, pdata);
    }
    json_append_member(state, "players", player_arr);

    json_append_member(state, "shared_gold",
                       json_mknumber(mp_state.shared_gold));

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
        if (n == 0 || (errno != EAGAIN && errno != EWOULDBLOCK))
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
