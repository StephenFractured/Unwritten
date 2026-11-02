-- Edit these, then press F3 in game to connect.
return {
  server = "127.0.0.1",   -- the PC running unwritten-server (use its LAN or public IP for a friend)
  port = 30120,
  name = "Stephen",
  interpDelay = 0.10,      -- seconds remote players are rendered in the past (smooths jitter)
  sendHz = 30,
  -- Test with one PC: start the server with "--echo 1" and your own movement comes back from the
  -- server as a puppet trailing you by echoDelay seconds. Set false for real multiplayer.
  echoSelf = true,
  echoDelay = 1.5,
}
