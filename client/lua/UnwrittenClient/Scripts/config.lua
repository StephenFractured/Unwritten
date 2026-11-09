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
  -- Echo test only: your trailing puppet starts as a student's look and then receives yours from
  -- the server, so you can see appearance sync work. Stand near a student when you press F3.
  echoTestBase = true,
  logLook = true,          -- write your captured look to UE4SS.log (for debugging appearance sync)
}
