# Minecraft account commands

Use Paper 1.21.11 with Java 21, Skript 2.14.1 and the skript-reflect 2.6.3 addon.
The script uses Java's HTTP client and the Gson library bundled with Paper. It
does not require a second Skript addon.

1. Install Skript and skript-reflect into the Paper server's `plugins/` directory.
2. Create `/etc/rofront/minecraft-internal.key` outside the server's plugin directory.
   Put the value of the account service's `INTERNAL_KEY` on one line without
   quotes. Own it with the OS user running the Paper server and set mode 600.
   Keep the file out of backups and logs that are available to players.
3. Install `rofront-accounts.sk` in `plugins/Skript/scripts/`. On your next
   maintenance cycle, load it with `skript reload rofront-accounts`. Check the
   console for parser errors. Run this on a test server before production.
4. The Paper process must be able to reach the account service over loopback at
   `http://127.0.0.1:8071/api/v1/internal/mc-confirm`. Paper and accounts must
   share a network namespace, so separate containers need an appropriate local
   deployment arrangement. Leave the public nginx block for internal endpoints in place.

Players use `/link ABCD-2345` or `/recover WXYZ-5678` with the code shown in
RoFront. The account service determines the action from the code's kind. Get
the UUID from a server that authenticates its players, either directly or
through a correctly configured authenticated proxy. Both commands share five
attempts per minute per UUID. The HTTP function runs off the Minecraft tick
thread and uses a five-second connect and request timeout.

For a manual smoke test, try both commands as a player and as console, an
expired code, an unrecognized code, a UUID already linked elsewhere, and a
recovery code from a different Minecraft account. Then verify that a valid
link and recovery complete when used by the expected player.
