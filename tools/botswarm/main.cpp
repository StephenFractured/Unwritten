// Bot swarm: N fake players that connect to the Unwritten server, wander around a shared
// area and measure how well they see each other. Used for the Phase 0 "128 players in
// sync" gate without needing 128 copies of the game.
//
// Usage: botswarm [--host 127.0.0.1] [--port 30120] [--bots 128] [--seconds 30]
//                 [--area 20000]   (side of the square they wander in, cm; 20000 = 200 m)

#include <enet/enet.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <random>
#include <string>
#include <unordered_map>
#include <vector>

#include "protocol.hpp"

using Clock = std::chrono::steady_clock;

struct Bot {
  ENetHost* host = nullptr;
  ENetPeer* peer = nullptr;
  bool connected = false;
  uint16_t id = 0;
  uw::PlayerState st;
  uw::Vec3 target;
  uint64_t bytes_in = 0;
  uint64_t snap_packets = 0;
  uint64_t entries_seen = 0;
  uint32_t last_tick = 0;
  std::vector<double> snap_gaps_ms;
  Clock::time_point last_snap{};
  size_t max_visible = 0;
};

int main(int argc, char** argv) {
  std::string host_name = "127.0.0.1";
  uint16_t port = uw::kDefaultPort;
  int n = 128, seconds = 30;
  float area = 20000.f;
  for (int i = 1; i + 1 < argc; i += 2) {
    if (!std::strcmp(argv[i], "--host")) host_name = argv[i + 1];
    else if (!std::strcmp(argv[i], "--port")) port = uint16_t(std::atoi(argv[i + 1]));
    else if (!std::strcmp(argv[i], "--bots")) n = std::atoi(argv[i + 1]);
    else if (!std::strcmp(argv[i], "--seconds")) seconds = std::atoi(argv[i + 1]);
    else if (!std::strcmp(argv[i], "--area")) area = float(std::atof(argv[i + 1]));
  }
  if (enet_initialize() != 0) return 1;

  std::mt19937 rng(1234);
  std::uniform_real_distribution<float> U(0.f, area);
  auto rand_point = [&] { return uw::Vec3{U(rng), U(rng), 0.f}; };

  ENetAddress addr{};
  enet_address_set_host(&addr, host_name.c_str());
  addr.port = port;

  std::vector<Bot> bots(n);
  for (int i = 0; i < n; ++i) {
    Bot& b = bots[i];
    b.host = enet_host_create(nullptr, 1, uw::kChanCount, 0, 0);
    b.peer = enet_host_connect(b.host, &addr, uw::kChanCount, 0);
    b.st.pos = rand_point();
    b.target = rand_point();
  }
  // id -> bot index, so receivers can compare what they were told with the truth.
  std::unordered_map<uint16_t, int> by_id;
  std::vector<double> errors_cm;
  errors_cm.reserve(1 << 20);

  const auto start = Clock::now();
  const auto end = start + std::chrono::seconds(seconds);
  const auto send_every = std::chrono::microseconds(1000000 / uw::kTickRate);
  auto next_send = start;
  auto last_move = start;
  // Ignore the first 3 s while everyone connects.
  const auto measure_from = start + std::chrono::seconds(3);

  while (Clock::now() < end) {
    auto now = Clock::now();
    for (int i = 0; i < n; ++i) {
      Bot& b = bots[i];
      ENetEvent ev;
      while (enet_host_service(b.host, &ev, 0) > 0) {
        if (ev.type == ENET_EVENT_TYPE_CONNECT) {
          b.connected = true;
          auto hello = uw::EncodeHello("bot" + std::to_string(i));
          enet_peer_send(b.peer, uw::kChanReliable,
                         enet_packet_create(hello.data(), hello.size(), ENET_PACKET_FLAG_RELIABLE));
        } else if (ev.type == ENET_EVENT_TYPE_RECEIVE) {
          b.bytes_in += ev.packet->dataLength;
          uw::Reader r(ev.packet->data, ev.packet->dataLength);
          auto type = uw::Msg(r.u8());
          if (type == uw::Msg::Welcome) {
            b.id = r.u16();
            by_id[b.id] = i;
          } else if (type == uw::Msg::Snapshot) {
            uint32_t tick = r.u32();
            uint8_t cnt = r.u8();
            if (tick != b.last_tick) {
              if (b.last_snap.time_since_epoch().count() && now > measure_from)
                b.snap_gaps_ms.push_back(
                    std::chrono::duration<double, std::milli>(now - b.last_snap).count());
              b.last_snap = now;
              b.last_tick = tick;
            }
            b.snap_packets++;
            b.max_visible = std::max<size_t>(b.max_visible, cnt);
            for (int k = 0; k < cnt && r.ok(); ++k) {
              uw::SnapEntry e = uw::ReadSnapEntry(r);
              b.entries_seen++;
              auto it = by_id.find(e.id);
              if (it == by_id.end() || now < measure_from) continue;
              const auto& truth = bots[it->second].st.pos;
              double dx = e.x - truth.x, dy = e.y - truth.y, dz = e.z - truth.z;
              errors_cm.push_back(std::sqrt(dx * dx + dy * dy + dz * dz));
            }
          }
          enet_packet_destroy(ev.packet);
        } else if (ev.type == ENET_EVENT_TYPE_DISCONNECT) {
          b.connected = false;
        }
      }
    }

    // Move every bot towards its target at walking/sprinting speed.
    double dt = std::chrono::duration<double>(now - last_move).count();
    last_move = now;
    for (Bot& b : bots) {
      float dx = b.target.x - b.st.pos.x, dy = b.target.y - b.st.pos.y;
      float d = std::sqrt(dx * dx + dy * dy);
      float speed = (b.id % 4 == 0) ? 700.f : 400.f;
      if (d < 50.f) { b.target = rand_point(); continue; }
      float step = std::min<float>(d, speed * float(dt));
      b.st.pos.x += dx / d * step;
      b.st.pos.y += dy / d * step;
      b.st.yaw = std::atan2(dy, dx) * 57.29578f;
      b.st.speed = speed;
      b.st.anim_flags = (b.id % 4 == 0) ? uw::kAnimSprinting : 0;
    }

    if (now >= next_send) {
      next_send += send_every;
      for (Bot& b : bots) {
        if (!b.connected || !b.id) continue;
        b.st.seq++;
        auto pkt = uw::EncodePlayerState(b.st);
        enet_peer_send(b.peer, uw::kChanUnreliable, enet_packet_create(pkt.data(), pkt.size(), 0));
        enet_host_flush(b.host);
      }
    }
  }

  // ---- report
  double secs = seconds;
  int connected = 0;
  double kbps_total = 0;
  std::vector<double> gaps;
  for (Bot& b : bots) {
    connected += b.connected && b.id;
    kbps_total += b.bytes_in / 1024.0 / secs;
    gaps.insert(gaps.end(), b.snap_gaps_ms.begin(), b.snap_gaps_ms.end());
  }
  auto pct = [](std::vector<double>& v, double p) {
    if (v.empty()) return 0.0;
    size_t k = std::min(v.size() - 1, size_t(p * (v.size() - 1)));
    std::nth_element(v.begin(), v.begin() + k, v.end());
    return v[k];
  };
  std::printf("\n=== botswarm report: %d bots, %d s, area %.0f m square ===\n", n, seconds, area / 100);
  std::printf("connected and welcomed : %d / %d\n", connected, n);
  std::printf("download per player    : %.1f KB/s avg\n", connected ? kbps_total / connected : 0);
  std::printf("snapshot interval (ms) : p50 %.1f  p95 %.1f  p99 %.1f\n", pct(gaps, .5), pct(gaps, .95),
              pct(gaps, .99));
  std::printf("position error (cm)    : p50 %.1f  p95 %.1f  p99 %.1f  (%zu samples, raw, before interpolation)\n",
              pct(errors_cm, .5), pct(errors_cm, .95), pct(errors_cm, .99), errors_cm.size());
  size_t maxvis = 0;
  for (Bot& b : bots) maxvis = std::max(maxvis, b.max_visible);
  std::printf("max entries in one pkt : %zu (cap %zu)\n", maxvis, uw::kMaxEntriesPerPacket);

  for (Bot& b : bots) {
    if (b.peer) enet_peer_disconnect_now(b.peer, 0);
    enet_host_destroy(b.host);
  }
  enet_deinitialize();
  return connected == n ? 0 : 2;
}
