// Unwritten sync server (Phase 0 spike).
//
// Job: accept players, take each player's movement/animation state, sanity-check it,
// and fan it out to every other player who is close enough to care.
// Movement is client-predicted with server validation (the server has no copy of the
// game world's collision), the same model FiveM/RedM use. Everything that matters for
// gameplay (money, damage, inventory) will be server-authoritative in Phase 1.
//
// Usage: unwritten-server [--port 30120] [--max 128] [--echo 1]
//   --echo 1  test mode: each player also receives its own state, so one PC can see
//             itself as a remote player (the client draws it as a trailing puppet).

#include <enet/enet.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unordered_map>
#include <vector>

#include "protocol.hpp"

using Clock = std::chrono::steady_clock;

namespace {

struct Player {
  uint16_t id = 0;
  ENetPeer* peer = nullptr;
  std::string name;
  std::string appearance;  // empty until the client sends its look
  bool hello = false;     // completed handshake
  bool has_state = false; // has sent at least one PlayerState
  uw::PlayerState state;
  Clock::time_point last_state_time;
  int corrections = 0;
};

struct Stats {
  uint64_t bytes_out = 0, packets_out = 0, bytes_in = 0, corrections = 0;
  double tick_ms_total = 0, tick_ms_max = 0;
  uint64_t ticks = 0;
};

float Dist2(const uw::Vec3& a, const uw::Vec3& b) {
  float dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
  return dx * dx + dy * dy + dz * dz;
}

// Uniform 2D grid over x/y for neighbour queries. Rebuilt every tick: with a few hundred
// players this costs microseconds and avoids incremental bookkeeping bugs.
class Grid {
 public:
  static constexpr float kCell = 10000.f;  // 100 m
  void Clear() { cells_.clear(); }
  void Insert(Player* p) { cells_[Key(Cx(p->state.pos.x), Cx(p->state.pos.y))].push_back(p); }
  template <class F>
  void Query(const uw::Vec3& c, float r, F&& f) const {
    int r_cells = static_cast<int>(std::ceil(r / kCell));
    int cx = Cx(c.x), cy = Cx(c.y);
    for (int dx = -r_cells; dx <= r_cells; ++dx)
      for (int dy = -r_cells; dy <= r_cells; ++dy) {
        auto it = cells_.find(Key(cx + dx, cy + dy));
        if (it == cells_.end()) continue;
        for (Player* p : it->second) f(p);
      }
  }

 private:
  static int Cx(float v) { return static_cast<int>(std::floor(v / kCell)); }
  static int64_t Key(int x, int y) { return (int64_t(x) << 32) ^ uint32_t(y); }
  std::unordered_map<int64_t, std::vector<Player*>> cells_;
};

class Server {
 public:
  bool Start(uint16_t port, int max_players) {
    max_players_ = max_players;
    ENetAddress addr{};
    addr.host = ENET_HOST_ANY;
    addr.port = port;
    host_ = enet_host_create(&addr, static_cast<size_t>(max_players), uw::kChanCount, 0, 0);
    if (!host_) { std::fprintf(stderr, "could not bind UDP port %u\n", port); return false; }
    std::printf("Unwritten server listening on UDP %u, max %d players, tick %d Hz\n", port,
                max_players, uw::kTickRate);
    return true;
  }

  void Run() {
    const auto tick_len = std::chrono::microseconds(1000000 / uw::kTickRate);
    auto next_tick = Clock::now() + tick_len;
    auto next_report = Clock::now() + std::chrono::seconds(5);
    for (;;) {
      auto now = Clock::now();
      auto wait_ms = std::chrono::duration_cast<std::chrono::milliseconds>(next_tick - now).count();
      ENetEvent ev;
      if (enet_host_service(host_, &ev, static_cast<enet_uint32>(std::max<long long>(0, wait_ms))) > 0) {
        Handle(ev);
        while (enet_host_check_events(host_, &ev) > 0) Handle(ev);
      }
      now = Clock::now();
      if (now >= next_tick) {
        auto t0 = Clock::now();
        Tick();
        double ms = std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
        stats_.tick_ms_total += ms;
        stats_.tick_ms_max = std::max(stats_.tick_ms_max, ms);
        stats_.ticks++;
        next_tick += tick_len;
        if (now - next_tick > std::chrono::seconds(1)) next_tick = now + tick_len;  // fell behind badly
      }
      if (now >= next_report) { Report(); next_report = now + std::chrono::seconds(5); }
    }
  }

 private:
  void Send(Player& p, uint8_t chan, const std::vector<uint8_t>& data, bool reliable) {
    ENetPacket* pkt = enet_packet_create(data.data(), data.size(),
                                         reliable ? ENET_PACKET_FLAG_RELIABLE : 0);
    enet_peer_send(p.peer, chan, pkt);
    stats_.bytes_out += data.size();
    stats_.packets_out++;
  }

  void Handle(const ENetEvent& ev) {
    switch (ev.type) {
      case ENET_EVENT_TYPE_CONNECT: {
        uint16_t id = next_id_++;
        if (next_id_ == 0) next_id_ = 1;
        Player& p = players_[id];
        p.id = id;
        p.peer = ev.peer;
        ev.peer->data = reinterpret_cast<void*>(static_cast<uintptr_t>(id));
        enet_peer_timeout(ev.peer, 0, 5000, 10000);
        break;
      }
      case ENET_EVENT_TYPE_DISCONNECT: {
        auto id = static_cast<uint16_t>(reinterpret_cast<uintptr_t>(ev.peer->data));
        auto it = players_.find(id);
        if (it == players_.end()) break;
        bool announced = it->second.hello;
        std::printf("- %s (#%u) left\n", it->second.name.c_str(), id);
        players_.erase(it);
        if (announced)
          for (auto& [oid, o] : players_)
            if (o.hello) Send(o, uw::kChanReliable, uw::EncodeLeft(id), true);
        break;
      }
      case ENET_EVENT_TYPE_RECEIVE: {
        auto id = static_cast<uint16_t>(reinterpret_cast<uintptr_t>(ev.peer->data));
        auto it = players_.find(id);
        stats_.bytes_in += ev.packet->dataLength;
        if (it != players_.end()) OnPacket(it->second, ev.packet->data, ev.packet->dataLength);
        enet_packet_destroy(ev.packet);
        break;
      }
      default: break;
    }
  }

  void OnPacket(Player& p, const uint8_t* data, size_t len) {
    uw::Reader r(data, len);
    auto type = static_cast<uw::Msg>(r.u8());
    if (type == uw::Msg::Hello) {
      if (p.hello) return;
      uint16_t ver = r.u16();
      std::string name = r.str();
      if (!r.ok() || ver != uw::kProtocolVersion) { enet_peer_disconnect(p.peer, 1); return; }
      p.name = name.empty() ? "player" : name;
      p.hello = true;
      Send(p, uw::kChanReliable, uw::EncodeWelcome(p.id), true);
      for (auto& [oid, o] : players_) {
        if (oid == p.id || !o.hello) continue;
        Send(p, uw::kChanReliable, uw::EncodeJoined(oid, o.name), true);
        if (!o.appearance.empty())
          Send(p, uw::kChanReliable, uw::EncodePlayerAppearance(oid, o.appearance), true);
        Send(o, uw::kChanReliable, uw::EncodeJoined(p.id, p.name), true);
      }
      std::printf("+ %s (#%u) joined, %zu online\n", p.name.c_str(), p.id, players_.size());
      return;
    }
    if (type == uw::Msg::Appearance && p.hello) {
      std::string blob = r.lstr();
      if (!r.ok() || blob.empty() || blob.size() > uw::kMaxAppearanceBytes) return;
      p.appearance = std::move(blob);
      auto pkt = uw::EncodePlayerAppearance(p.id, p.appearance);
      for (auto& [oid, o] : players_)
        if (o.hello && (oid != p.id || echo_)) Send(o, uw::kChanReliable, pkt, true);
      std::printf("  %s (#%u) appearance: %zu bytes\n", p.name.c_str(), p.id, p.appearance.size());
      return;
    }
    if (type == uw::Msg::PlayerState && p.hello) {
      uw::PlayerState s;
      if (!uw::DecodePlayerState(r, s)) return;
      if (p.has_state && int32_t(s.seq - p.state.seq) <= 0) return;  // stale or duplicate
      auto now = Clock::now();
      if (p.has_state) {
        double dt = std::chrono::duration<double>(now - p.last_state_time).count();
        float moved = std::sqrt(Dist2(s.pos, p.state.pos));
        // Generous allowance: jitter can bunch packets together, so budget for 0.25 s minimum.
        float allowed = uw::kMaxSpeedCmPerSec * static_cast<float>(std::max(dt, 0.25)) * 1.5f + 200.f;
        if (moved > allowed) {
          p.corrections++;
          stats_.corrections++;
          Send(p, uw::kChanReliable, uw::EncodeCorrection(p.state.pos), true);
          return;
        }
      }
      p.state = s;
      p.has_state = true;
      p.last_state_time = now;
    }
  }

  static bool RateTick(uint64_t tick, int rate) {
    // true on the ticks where a `rate` Hz stream should fire, given kTickRate.
    return (tick * rate) / uw::kTickRate != ((tick - 1) * rate) / uw::kTickRate;
  }

  void Tick() {
    ++tick_;
    bool near_tick = RateTick(tick_, uw::kSnapshotRateNear);
    bool far_tick = RateTick(tick_, uw::kSnapshotRateFar);
    if (!near_tick && !far_tick) return;

    grid_.Clear();
    for (auto& [id, p] : players_)
      if (p.hello && p.has_state) grid_.Insert(&p);

    const float near2 = uw::kNearRadiusCm * uw::kNearRadiusCm;
    const float far2 = uw::kFarRadiusCm * uw::kFarRadiusCm;
    std::vector<std::pair<float, Player*>> cands;
    std::vector<uw::SnapEntry> entries;

    for (auto& [id, viewer] : players_) {
      if (!viewer.hello || !viewer.has_state) continue;
      cands.clear();
      grid_.Query(viewer.state.pos, uw::kFarRadiusCm, [&](Player* o) {
        if (o == &viewer && !echo_) return;
        float d2 = Dist2(o->state.pos, viewer.state.pos);
        if (d2 <= far2) cands.emplace_back(d2, o);
      });
      std::sort(cands.begin(), cands.end(),
                [](const auto& a, const auto& b) { return a.first < b.first; });
      entries.clear();
      for (size_t i = 0; i < cands.size(); ++i) {
        bool is_near = cands[i].first <= near2 && i < size_t(uw::kMaxNearEntities);
        if ((is_near && near_tick) || far_tick)
          entries.push_back(uw::MakeSnapEntry(cands[i].second->id, cands[i].second->state));
      }
      if (entries.empty()) continue;
      for (auto& pkt : uw::EncodeSnapshots(static_cast<uint32_t>(tick_), entries))
        Send(viewer, uw::kChanUnreliable, pkt, false);
    }
    enet_host_flush(host_);
  }

  void Report() {
    size_t online = 0;
    for (auto& [id, p] : players_) online += p.hello;
    double secs = 5.0;
    std::printf(
        "[stats] online=%zu out=%.1f KB/s (%.0f pkt/s) in=%.1f KB/s tick avg=%.3f ms max=%.3f ms "
        "corrections=%llu\n",
        online, stats_.bytes_out / 1024.0 / secs, stats_.packets_out / secs,
        stats_.bytes_in / 1024.0 / secs, stats_.ticks ? stats_.tick_ms_total / stats_.ticks : 0.0,
        stats_.tick_ms_max, static_cast<unsigned long long>(stats_.corrections));
    std::fflush(stdout);
    stats_ = {};
  }

  ENetHost* host_ = nullptr;
  int max_players_ = 128;

 public:
  bool echo_ = false;

 private:
  uint16_t next_id_ = 1;
  uint64_t tick_ = 0;
  std::unordered_map<uint16_t, Player> players_;
  Grid grid_;
  Stats stats_;
};

}  // namespace

int main(int argc, char** argv) {
  uint16_t port = uw::kDefaultPort;
  int max_players = 128;
  bool echo = false;
  for (int i = 1; i + 1 < argc; i += 2) {
    if (!std::strcmp(argv[i], "--port")) port = static_cast<uint16_t>(std::atoi(argv[i + 1]));
    else if (!std::strcmp(argv[i], "--max")) max_players = std::atoi(argv[i + 1]);
    else if (!std::strcmp(argv[i], "--echo")) echo = std::atoi(argv[i + 1]) != 0;
  }
  if (enet_initialize() != 0) { std::fprintf(stderr, "enet init failed\n"); return 1; }
  atexit(enet_deinitialize);
  Server s;
  s.echo_ = echo;
  if (echo) std::printf("echo mode: players receive their own state\n");
  if (!s.Start(port, max_players)) return 1;
  s.Run();
}
