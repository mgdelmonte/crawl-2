/**
 * @file
 * @brief Multiplayer TCP server (host side).
**/

#pragma once

#include <string>
#include <vector>

// Forward declarations to avoid pulling in system headers.
struct mp_client_conn
{
    int socket_fd = -1;
    int player_idx = -1;
    bool connected = false;
    std::string recv_buffer;    // partial data received
    std::string name;
};

class MPServer
{
public:
    MPServer();
    ~MPServer();

    // Start listening on the given port. Returns true on success.
    bool start(int port, int expected_players);

    // Stop the server and close all connections.
    void stop();

    // Wait for all clients to connect. Blocks until all expected clients
    // have connected or returns false on error.
    bool wait_for_connections();

    // Try to accept one pending connection, waiting up to poll_timeout_ms.
    // Returns true if a new client was accepted, false otherwise.
    // Sets error_out to true if a fatal error occurred.
    bool try_accept_connection(bool& error_out, int poll_timeout_ms = 100);

    // Returns true if all expected clients are connected.
    bool all_connected() const;

    // Poll for incoming commands from clients (non-blocking).
    // Returns a vector of (player_index, json_command_string) pairs.
    std::vector<std::pair<int, std::string>> poll_commands();

    // Send a JSON message to a specific client.
    void send_to(int player_idx, const std::string& json_msg);

    // Broadcast a JSON message to all connected clients.
    void broadcast(const std::string& json_msg);

    // Send a game state update to all clients.
    void broadcast_game_state();

    // Send a turn_start notification to a specific client.
    void send_turn_start(int player_idx, int turn);

    // Broadcast dungeon level data (grid features) to all clients.
    void broadcast_level_data();

    bool is_running() const { return m_running; }
    int num_connected() const;
    bool is_player_connected(int player_idx) const;
    const std::string& last_error() const { return m_last_error; }

private:
    int m_listen_fd = -1;
    bool m_running = false;
    int m_expected_players = 1;
    std::vector<mp_client_conn> m_clients;
    std::string m_last_error;

    // Read available data from a client socket, extract complete
    // newline-delimited JSON messages.
    std::vector<std::string> read_messages(mp_client_conn& client);
};

extern MPServer mp_server;
