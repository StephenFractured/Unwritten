// UnwrittenClient native half: the network bridge.
//
// UE4SS pairs a C++ mod with the Lua mod of the same name (folder UnwrittenClient with
// dlls/main.dll and Scripts/main.lua). This DLL owns the UDP connection on a background
// thread and exposes four functions to that Lua script:
//
//   UW_Connect(host, port, name)                       -> true/false
//   UW_SendState(x, y, z, yaw, speed, flags, montage, montageSeq)
//   UW_SetAppearance(blob)                             my look; sent now and on every reconnect
//   UW_Poll()                                          -> array of event tables
//   UW_Disconnect()
//
// All game-object work (spawning puppets, moving them, reading the player) stays in Lua
// so we can iterate without recompiling. Move hot paths into C++ later if Lua is too slow.
//
// Built against RE-UE4SS main @ 1ceefac8 (reports itself as "v3.0.1 Beta"), the exact build
// installed in the game. If you change UE4SS versions, check on_lua_start and register_function.

#include <Mod/CppUserModBase.hpp>
#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <lua.hpp>

#include <enet/enet.h>

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "protocol.hpp"

using namespace RC;

namespace {

struct Event {
  enum Kind { Welcome, Joined, Left, State, Correction, Disconnected, Appearance } kind;
  uint16_t id = 0;
  std::string name;
  uint32_t tick = 0;
  uw::SnapEntry e{};
  uw::Vec3 pos;
};

class NetBridge {
 public:
  bool Connect(const std::string& host, uint16_t port, const std::string& name) {
    Disconnect();
    if (!enet_ready_) { if (enet_initialize() != 0) return false; enet_ready_ = true; }
    host_ = enet_host_create(nullptr, 1, uw::kChanCount, 0, 0);
    if (!host_) return false;
    ENetAddress addr{};
    if (enet_address_set_host(&addr, host.c_str()) != 0) return false;
    addr.port = port;
    peer_ = enet_host_connect(host_, &addr, uw::kChanCount, 0);
    if (!peer_) return false;
    name_ = name;
    running_ = true;
    thread_ = std::thread([this] { Loop(); });
    return true;
  }

  void Disconnect() {
    running_ = false;
    if (thread_.joinable()) thread_.join();
    if (peer_) { enet_peer_disconnect_now(peer_, 0); peer_ = nullptr; }
    if (host_) { enet_host_destroy(host_); host_ = nullptr; }
  }

  // Called from the game thread. Latest state wins; the net thread sends it.
  void SetState(const uw::PlayerState& s) {
    std::lock_guard lk(out_mu_);
    pending_ = s;
    has_pending_ = true;
  }

  void SetAppearance(const std::string& blob) {
    std::lock_guard lk(out_mu_);
    appearance_ = blob;
    appearance_dirty_ = true;
  }

  std::vector<Event> Drain() {
    std::lock_guard lk(in_mu_);
    std::vector<Event> out;
    out.swap(inbox_);
    return out;
  }

  ~NetBridge() { Disconnect(); if (enet_ready_) enet_deinitialize(); }

 private:
  void Push(Event e) {
    std::lock_guard lk(in_mu_);
    if (inbox_.size() > 20000) inbox_.clear();  // game thread stalled (loading screen): drop backlog
    inbox_.push_back(std::move(e));
  }

  void Loop() {
    uint32_t seq = 0;
    while (running_) {
      ENetEvent ev;
      while (enet_host_service(host_, &ev, 5) > 0) {
        if (ev.type == ENET_EVENT_TYPE_CONNECT) {
          auto hello = uw::EncodeHello(name_);
          enet_peer_send(peer_, uw::kChanReliable,
                         enet_packet_create(hello.data(), hello.size(), ENET_PACKET_FLAG_RELIABLE));
        } else if (ev.type == ENET_EVENT_TYPE_DISCONNECT) {
          Push({Event::Disconnected});
          welcomed_ = false;
        } else if (ev.type == ENET_EVENT_TYPE_RECEIVE) {
          OnPacket(ev.packet->data, ev.packet->dataLength);
          enet_packet_destroy(ev.packet);
        }
      }
      if (welcomed_) {
        std::string look;
        {
          std::lock_guard lk(out_mu_);
          if (appearance_dirty_ && !appearance_.empty()) { look = appearance_; appearance_dirty_ = false; }
        }
        if (!look.empty()) {
          auto pkt = uw::EncodeAppearance(look);
          enet_peer_send(peer_, uw::kChanReliable,
                         enet_packet_create(pkt.data(), pkt.size(), ENET_PACKET_FLAG_RELIABLE));
        }
        uw::PlayerState s;
        bool send = false;
        {
          std::lock_guard lk(out_mu_);
          if (has_pending_) { s = pending_; has_pending_ = false; send = true; }
        }
        if (send) {
          s.seq = ++seq;
          auto pkt = uw::EncodePlayerState(s);
          enet_peer_send(peer_, uw::kChanUnreliable, enet_packet_create(pkt.data(), pkt.size(), 0));
          enet_host_flush(host_);
        }
      }
    }
  }

  void OnPacket(const uint8_t* d, size_t n) {
    uw::Reader r(d, n);
    switch (uw::Msg(r.u8())) {
      case uw::Msg::Welcome: {
        Event e{Event::Welcome}; e.id = r.u16(); welcomed_ = true;
        { std::lock_guard lk(out_mu_); appearance_dirty_ = true; }  // (re)send our look after every welcome
        Push(e); break;
      }
      case uw::Msg::PlayerAppearance: {
        Event e{Event::Appearance}; e.id = r.u16(); e.name = r.lstr(); if (r.ok()) Push(e); break;
      }
      case uw::Msg::PlayerJoined: { Event e{Event::Joined}; e.id = r.u16(); e.name = r.str(); Push(e); break; }
      case uw::Msg::PlayerLeft: { Event e{Event::Left}; e.id = r.u16(); Push(e); break; }
      case uw::Msg::Correction: {
        Event e{Event::Correction}; e.pos.x = r.f32(); e.pos.y = r.f32(); e.pos.z = r.f32(); Push(e); break;
      }
      case uw::Msg::Snapshot: {
        uint32_t tick = r.u32();
        uint8_t cnt = r.u8();
        for (int i = 0; i < cnt && r.ok(); ++i) {
          Event e{Event::State};
          e.tick = tick;
          e.e = uw::ReadSnapEntry(r);
          if (r.ok()) Push(e);
        }
        break;
      }
      default: break;
    }
  }

  ENetHost* host_ = nullptr;
  ENetPeer* peer_ = nullptr;
  std::string name_;
  std::thread thread_;
  std::atomic<bool> running_{false}, welcomed_{false};
  bool enet_ready_ = false;
  std::mutex out_mu_, in_mu_;
  uw::PlayerState pending_;
  bool has_pending_ = false;
  std::string appearance_;
  bool appearance_dirty_ = false;
  std::vector<Event> inbox_;
};

NetBridge g_net;

// ---------------------------------------------------------------- Lua bindings (raw C API)
void SetNum(lua_State* L, const char* k, double v) { lua_pushnumber(L, v); lua_setfield(L, -2, k); }
void SetStr(lua_State* L, const char* k, const char* v) { lua_pushstring(L, v); lua_setfield(L, -2, k); }

int L_Connect(const LuaMadeSimple::Lua& lua) {
  lua_State* L = lua.get_lua_state();
  const char* host = luaL_checkstring(L, 1);
  auto port = static_cast<uint16_t>(luaL_optinteger(L, 2, uw::kDefaultPort));
  const char* name = luaL_optstring(L, 3, "player");
  lua_pushboolean(L, g_net.Connect(host, port, name));
  return 1;
}

int L_SendState(const LuaMadeSimple::Lua& lua) {
  lua_State* L = lua.get_lua_state();
  uw::PlayerState s;
  s.pos = {float(luaL_checknumber(L, 1)), float(luaL_checknumber(L, 2)), float(luaL_checknumber(L, 3))};
  s.yaw = float(luaL_checknumber(L, 4));
  s.speed = float(luaL_optnumber(L, 5, 0));
  s.anim_flags = uint8_t(luaL_optinteger(L, 6, 0));
  s.montage_id = uint16_t(luaL_optinteger(L, 7, 0));
  s.montage_seq = uint8_t(luaL_optinteger(L, 8, 0));
  g_net.SetState(s);
  return 0;
}

int L_SetAppearance(const LuaMadeSimple::Lua& lua) {
  lua_State* L = lua.get_lua_state();
  size_t n = 0;
  const char* blob = luaL_checklstring(L, 1, &n);
  bool ok = n > 0 && n <= uw::kMaxAppearanceBytes;
  if (ok) g_net.SetAppearance(std::string(blob, n));
  lua_pushboolean(L, ok);
  return 1;
}

int L_Poll(const LuaMadeSimple::Lua& lua) {
  lua_State* L = lua.get_lua_state();
  auto events = g_net.Drain();
  lua_createtable(L, int(events.size()), 0);
  int i = 1;
  for (auto& ev : events) {
    lua_createtable(L, 0, 10);
    switch (ev.kind) {
      case Event::Welcome: SetStr(L, "type", "welcome"); SetNum(L, "id", ev.id); break;
      case Event::Joined: SetStr(L, "type", "joined"); SetNum(L, "id", ev.id); SetStr(L, "name", ev.name.c_str()); break;
      case Event::Left: SetStr(L, "type", "left"); SetNum(L, "id", ev.id); break;
      case Event::Disconnected: SetStr(L, "type", "disconnected"); break;
      case Event::Appearance:
        SetStr(L, "type", "appearance"); SetNum(L, "id", ev.id);
        lua_pushlstring(L, ev.name.data(), ev.name.size()); lua_setfield(L, -2, "data");
        break;
      case Event::Correction:
        SetStr(L, "type", "correction"); SetNum(L, "x", ev.pos.x); SetNum(L, "y", ev.pos.y); SetNum(L, "z", ev.pos.z);
        break;
      case Event::State:
        SetStr(L, "type", "state");
        SetNum(L, "tick", ev.tick); SetNum(L, "id", ev.e.id);
        SetNum(L, "x", ev.e.x); SetNum(L, "y", ev.e.y); SetNum(L, "z", ev.e.z);
        SetNum(L, "yaw", uw::DequantYaw(ev.e.yaw_q)); SetNum(L, "speed", ev.e.speed_q);
        SetNum(L, "flags", ev.e.anim_flags); SetNum(L, "montage", ev.e.montage_id); SetNum(L, "montageSeq", ev.e.montage_seq);
        break;
    }
    lua_rawseti(L, -2, i++);
  }
  return 1;
}

int L_Disconnect(const LuaMadeSimple::Lua&) { g_net.Disconnect(); return 0; }

}  // namespace

class UnwrittenClient : public CppUserModBase {
 public:
  UnwrittenClient() : CppUserModBase() {
    ModName = STR("UnwrittenClient");
    ModVersion = STR("0.0.2");
    ModDescription = STR("Unwritten Roleplay Phase 0 sync client");
    ModAuthors = STR("Unwritten");
    Output::send<LogLevel::Verbose>(STR("[Unwritten] native bridge loaded\n"));
  }
  ~UnwrittenClient() override { g_net.Disconnect(); }

  // Called when our paired Lua mod (Scripts/main.lua) starts. UE4SS (main @ 1ceefac8, the build
  // installed in the game) passes a single game-thread hook Lua instance.
  auto on_lua_start(LuaMadeSimple::Lua& lua, LuaMadeSimple::Lua& main_lua, LuaMadeSimple::Lua& async_lua,
                    LuaMadeSimple::Lua* hook_lua) -> void override {
    for (LuaMadeSimple::Lua* l : {&lua, &main_lua, &async_lua, hook_lua}) {
      if (!l) continue;
      l->register_function("UW_Connect", L_Connect);
      l->register_function("UW_SendState", L_SendState);
      l->register_function("UW_SetAppearance", L_SetAppearance);
      l->register_function("UW_Poll", L_Poll);
      l->register_function("UW_Disconnect", L_Disconnect);
    }
    Output::send<LogLevel::Verbose>(STR("[Unwritten] Lua functions registered\n"));
  }
};

#define UNWRITTEN_API __declspec(dllexport)
extern "C" {
UNWRITTEN_API CppUserModBase* start_mod() { return new UnwrittenClient(); }
UNWRITTEN_API void uninstall_mod(CppUserModBase* mod) { delete mod; }
}
