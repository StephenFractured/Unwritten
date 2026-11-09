// Unwritten wire protocol, shared by the server, the bot swarm and the client mod.
// Header-only, no dependencies beyond the standard library.
//
// Units follow Unreal: positions in centimetres, yaw in degrees.
// All integers are little-endian.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace uw {

constexpr uint16_t kProtocolVersion = 2;  // 2: appearance messages
constexpr uint16_t kDefaultPort = 30120;
constexpr int kTickRate = 30;          // server simulation ticks per second
constexpr int kSnapshotRateNear = 20;  // snapshots/s for players inside the near radius
constexpr int kSnapshotRateFar = 5;    // snapshots/s for players inside the far radius
constexpr float kNearRadiusCm = 8000.f;   // 80 m
constexpr float kFarRadiusCm = 30000.f;   // 300 m
constexpr int kMaxNearEntities = 64;      // hard cap per client per snapshot
constexpr size_t kMaxPacketBytes = 1200;  // stay under typical MTU, never fragment
constexpr size_t kMaxAppearanceBytes = 16384;  // appearance blob limit
constexpr float kMaxSpeedCmPerSec = 3000.f;  // sanity limit (broom flight is faster: raise in Phase 3)

enum Channel : uint8_t { kChanReliable = 0, kChanUnreliable = 1, kChanCount = 2 };

enum class Msg : uint8_t {
  // client -> server
  Hello = 1,        // reliable: protocol version + display name
  PlayerState = 2,  // unreliable sequenced: where I am and what I'm doing
  Appearance = 3,   // reliable: my look, as an appearance text blob (see client appearance.lua)
  // server -> client
  Welcome = 10,      // reliable: your player id
  PlayerJoined = 11, // reliable: id + name (+ appearance later)
  PlayerLeft = 12,   // reliable: id
  Snapshot = 13,     // unreliable: batch of other players' states
  Correction = 14,   // reliable: server rejected your position, snap back here
  PlayerAppearance = 15,  // reliable: id + that player's appearance blob
};

// Animation is synced as the handful of inputs the player's AnimBlueprint reads,
// not as bone transforms. The receiving puppet runs its own AnimBP from these.
enum AnimFlags : uint8_t {
  kAnimInAir = 1 << 0,
  kAnimCrouch = 1 << 1,
  kAnimWandOut = 1 << 2,
  kAnimSprinting = 1 << 3,
  kAnimSwimming = 1 << 4,
  kAnimMounted = 1 << 5,  // broom / mount, Phase 3
};

struct Vec3 { float x = 0, y = 0, z = 0; };

struct PlayerState {
  uint32_t seq = 0;         // client-side sequence, server drops older ones
  Vec3 pos;                 // cm, world space
  float yaw = 0;            // degrees
  float speed = 0;          // cm/s ground speed, drives locomotion blend space
  uint8_t anim_flags = 0;   // AnimFlags
  uint16_t montage_id = 0;  // 0 = none; index into a shared montage table (spells, emotes)
  uint8_t montage_seq = 0;  // bumps each time a montage starts so repeats replay
};

// One entry inside a Snapshot. Quantised: 21 bytes.
struct SnapEntry {
  uint16_t id;
  int32_t x, y, z;      // cm
  uint16_t yaw_q;       // yaw * 65536/360
  uint16_t speed_q;     // cm/s
  uint8_t anim_flags;
  uint16_t montage_id;
  uint8_t montage_seq;
};
constexpr size_t kSnapEntryBytes = 2 + 12 + 2 + 2 + 1 + 2 + 1;
constexpr size_t kSnapshotHeaderBytes = 1 + 4 + 1;  // msg, server tick, count
constexpr size_t kMaxEntriesPerPacket = (kMaxPacketBytes - kSnapshotHeaderBytes) / kSnapEntryBytes;

inline uint16_t QuantYaw(float deg) {
  float d = std::fmod(deg, 360.f);
  if (d < 0) d += 360.f;
  return static_cast<uint16_t>(std::lround(d * 65536.f / 360.f) & 0xFFFF);
}
inline float DequantYaw(uint16_t q) { return q * 360.f / 65536.f; }

// ---------------------------------------------------------------- byte I/O
class Writer {
 public:
  std::vector<uint8_t> buf;
  void u8(uint8_t v) { buf.push_back(v); }
  void u16(uint16_t v) { raw(&v, 2); }
  void u32(uint32_t v) { raw(&v, 4); }
  void i32(int32_t v) { raw(&v, 4); }
  void f32(float v) { raw(&v, 4); }
  void str(const std::string& s) {
    uint8_t n = static_cast<uint8_t>(s.size() > 255 ? 255 : s.size());
    u8(n);
    buf.insert(buf.end(), s.begin(), s.begin() + n);
  }
  // Long string: u16 length.
  void lstr(const std::string& s) {
    uint16_t n = static_cast<uint16_t>(s.size() > 65535 ? 65535 : s.size());
    u16(n);
    buf.insert(buf.end(), s.begin(), s.begin() + n);
  }
  void raw(const void* p, size_t n) {
    auto b = static_cast<const uint8_t*>(p);
    buf.insert(buf.end(), b, b + n);
  }
};

class Reader {
 public:
  Reader(const uint8_t* d, size_t n) : d_(d), n_(n) {}
  bool ok() const { return ok_; }
  size_t remaining() const { return n_ - p_; }
  uint8_t u8() { uint8_t v = 0; raw(&v, 1); return v; }
  uint16_t u16() { uint16_t v = 0; raw(&v, 2); return v; }
  uint32_t u32() { uint32_t v = 0; raw(&v, 4); return v; }
  int32_t i32() { int32_t v = 0; raw(&v, 4); return v; }
  float f32() { float v = 0; raw(&v, 4); return v; }
  std::string str() {
    uint8_t n = u8();
    if (!ok_ || remaining() < n) { ok_ = false; return {}; }
    std::string s(reinterpret_cast<const char*>(d_ + p_), n);
    p_ += n;
    return s;
  }
  std::string lstr() {
    uint16_t n = u16();
    if (!ok_ || remaining() < n) { ok_ = false; return {}; }
    std::string s(reinterpret_cast<const char*>(d_ + p_), n);
    p_ += n;
    return s;
  }
  void raw(void* out, size_t n) {
    if (!ok_ || remaining() < n) { ok_ = false; std::memset(out, 0, n); return; }
    std::memcpy(out, d_ + p_, n);
    p_ += n;
  }

 private:
  const uint8_t* d_;
  size_t n_, p_ = 0;
  bool ok_ = true;
};

// ---------------------------------------------------------------- messages
inline std::vector<uint8_t> EncodeHello(const std::string& name) {
  Writer w; w.u8(uint8_t(Msg::Hello)); w.u16(kProtocolVersion); w.str(name); return w.buf;
}
inline std::vector<uint8_t> EncodeWelcome(uint16_t id) {
  Writer w; w.u8(uint8_t(Msg::Welcome)); w.u16(id); w.u8(kTickRate); return w.buf;
}
inline std::vector<uint8_t> EncodeJoined(uint16_t id, const std::string& name) {
  Writer w; w.u8(uint8_t(Msg::PlayerJoined)); w.u16(id); w.str(name); return w.buf;
}
inline std::vector<uint8_t> EncodeLeft(uint16_t id) {
  Writer w; w.u8(uint8_t(Msg::PlayerLeft)); w.u16(id); return w.buf;
}
inline std::vector<uint8_t> EncodeAppearance(const std::string& blob) {
  Writer w; w.u8(uint8_t(Msg::Appearance)); w.lstr(blob); return w.buf;
}
inline std::vector<uint8_t> EncodePlayerAppearance(uint16_t id, const std::string& blob) {
  Writer w; w.u8(uint8_t(Msg::PlayerAppearance)); w.u16(id); w.lstr(blob); return w.buf;
}
inline std::vector<uint8_t> EncodeCorrection(const Vec3& p) {
  Writer w; w.u8(uint8_t(Msg::Correction)); w.f32(p.x); w.f32(p.y); w.f32(p.z); return w.buf;
}

inline std::vector<uint8_t> EncodePlayerState(const PlayerState& s) {
  Writer w;
  w.u8(uint8_t(Msg::PlayerState));
  w.u32(s.seq);
  w.f32(s.pos.x); w.f32(s.pos.y); w.f32(s.pos.z);
  w.f32(s.yaw); w.f32(s.speed);
  w.u8(s.anim_flags); w.u16(s.montage_id); w.u8(s.montage_seq);
  return w.buf;
}
inline bool DecodePlayerState(Reader& r, PlayerState& s) {
  s.seq = r.u32();
  s.pos.x = r.f32(); s.pos.y = r.f32(); s.pos.z = r.f32();
  s.yaw = r.f32(); s.speed = r.f32();
  s.anim_flags = r.u8(); s.montage_id = r.u16(); s.montage_seq = r.u8();
  return r.ok() && std::isfinite(s.pos.x) && std::isfinite(s.pos.y) && std::isfinite(s.pos.z) &&
         std::isfinite(s.yaw) && std::isfinite(s.speed);
}

inline SnapEntry MakeSnapEntry(uint16_t id, const PlayerState& s) {
  SnapEntry e{};
  e.id = id;
  e.x = static_cast<int32_t>(std::lround(s.pos.x));
  e.y = static_cast<int32_t>(std::lround(s.pos.y));
  e.z = static_cast<int32_t>(std::lround(s.pos.z));
  e.yaw_q = QuantYaw(s.yaw);
  float sp = s.speed < 0 ? 0 : (s.speed > 65535.f ? 65535.f : s.speed);
  e.speed_q = static_cast<uint16_t>(sp);
  e.anim_flags = s.anim_flags;
  e.montage_id = s.montage_id;
  e.montage_seq = s.montage_seq;
  return e;
}

inline void WriteSnapEntry(Writer& w, const SnapEntry& e) {
  w.u16(e.id); w.i32(e.x); w.i32(e.y); w.i32(e.z);
  w.u16(e.yaw_q); w.u16(e.speed_q); w.u8(e.anim_flags); w.u16(e.montage_id); w.u8(e.montage_seq);
}
inline SnapEntry ReadSnapEntry(Reader& r) {
  SnapEntry e{};
  e.id = r.u16(); e.x = r.i32(); e.y = r.i32(); e.z = r.i32();
  e.yaw_q = r.u16(); e.speed_q = r.u16(); e.anim_flags = r.u8();
  e.montage_id = r.u16(); e.montage_seq = r.u8();
  return e;
}

// Splits entries into as many MTU-safe packets as needed.
inline std::vector<std::vector<uint8_t>> EncodeSnapshots(uint32_t tick, const std::vector<SnapEntry>& es) {
  std::vector<std::vector<uint8_t>> out;
  for (size_t i = 0; i < es.size(); i += kMaxEntriesPerPacket) {
    size_t n = std::min(kMaxEntriesPerPacket, es.size() - i);
    Writer w;
    w.buf.reserve(kSnapshotHeaderBytes + n * kSnapEntryBytes);
    w.u8(uint8_t(Msg::Snapshot)); w.u32(tick); w.u8(static_cast<uint8_t>(n));
    for (size_t j = 0; j < n; ++j) WriteSnapEntry(w, es[i + j]);
    out.push_back(std::move(w.buf));
  }
  return out;
}

}  // namespace uw
