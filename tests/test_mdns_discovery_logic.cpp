//
//  test_mdns_discovery_logic.cpp
//  Comprehensive Unit Tests for mDNS / Bonjour Logic, Service Deduplication, and Self-Filtering
//

#include <iostream>
#include <vector>
#include <string>
#include <map>
#include <cstdint>
#include <cassert>
#include <cstring>
#include <arpa/inet.h>
#include <netinet/in.h>

struct ServiceKey {
    std::string name;
    std::string regtype;
    std::string domain;

    bool operator<(const ServiceKey& o) const {
        if (name != o.name) return name < o.name;
        if (regtype != o.regtype) return regtype < o.regtype;
        return domain < o.domain;
    }
};

struct DiscoveredServerInfo {
    std::string name;
    std::string host;
    uint16_t port{0};
    std::string path;
};

// Simulate IPv4 extraction from sockaddr_in
std::string extract_ipv4_from_sockaddr(const struct sockaddr_in& sin) {
    char buffer[INET_ADDRSTRLEN];
    const char* res = inet_ntop(AF_INET, &(sin.sin_addr), buffer, sizeof(buffer));
    return res ? std::string(buffer) : "";
}

// Simulate self-filtering logic
bool is_self_device(const std::string& srv_name, uint16_t srv_port, const std::string& local_name, uint16_t local_port) {
    if (srv_port == local_port && srv_name == local_name) {
        return true;
    }
    return false;
}

int main() {
    std::cout << "=== Running mDNS Service Key & Map Deduplication Tests ===" << std::endl;
    {
        std::map<ServiceKey, DiscoveredServerInfo> server_map;

        ServiceKey k1{"Music Assistant", "_sendspin._tcp", "local."};
        server_map[k1] = {"Music Assistant", "192.168.1.152", 8927, "/sendspin"};

        // Re-adding identical key should update in-place without duplicating
        ServiceKey k1_dup{"Music Assistant", "_sendspin._tcp", "local."};
        server_map[k1_dup] = {"Music Assistant", "192.168.1.152", 8927, "/sendspin"};
        assert(server_map.size() == 1);

        // Adding distinct service
        ServiceKey k2{"Sendspin Room 2", "_sendspin._tcp", "local."};
        server_map[k2] = {"Sendspin Room 2", "192.168.1.180", 8927, "/sendspin"};
        assert(server_map.size() == 2);

        // Removing k1
        server_map.erase(k1);
        assert(server_map.size() == 1);
        assert(server_map.begin()->second.name == "Sendspin Room 2");

        std::cout << " [PASS] ServiceKey ordering and Map deduplication verified" << std::endl;
    }

    std::cout << "=== Running IPv4 Binary Address Parsing Tests ===" << std::endl;
    {
        struct sockaddr_in sin;
        std::memset(&sin, 0, sizeof(sin));
        sin.sin_family = AF_INET;
        sin.sin_port = htons(8927);
        inet_pton(AF_INET, "192.168.1.152", &sin.sin_addr);

        std::string ip_str = extract_ipv4_from_sockaddr(sin);
        assert(ip_str == "192.168.1.152");
        assert(ntohs(sin.sin_port) == 8927);

        // Test localhost
        inet_pton(AF_INET, "127.0.0.1", &sin.sin_addr);
        assert(extract_ipv4_from_sockaddr(sin) == "127.0.0.1");

        std::cout << " [PASS] sockaddr_in IPv4 extraction bit-exact" << std::endl;
    }

    std::cout << "=== Running Self-Filtering & Loopback Prevention Tests ===" << std::endl;
    {
        std::string my_player_name = "Sendspin Player";
        uint16_t my_port = 8928;

        // Remote server: Music Assistant on 8927 -> NOT self
        assert(!is_self_device("Music Assistant", 8927, my_player_name, my_port));

        // Remote player: "Living Room 4s" on 8928 -> NOT self
        assert(!is_self_device("Living Room 4s", 8928, my_player_name, my_port));

        // Self player broadcast: "Sendspin Player" on 8928 -> IS self (must be filtered out)
        assert(is_self_device("Sendspin Player", 8928, my_player_name, my_port));

        std::cout << " [PASS] Self-filtering rules validated" << std::endl;
    }

    std::cout << "\n>>> ALL MDNS & DISCOVERY LOGIC UNIT TESTS PASSED (100%) <<<" << std::endl;
    return 0;
}
