# Prompt for the Claude on the Oracle VM (deploy the Frontline Conquest server side)

Paste everything below into the VM Claude. Do the steps in order, stop and report if one fails.

---

You are deploying the game server and account service for Frontline Conquest on this VM. Rules: never print or commit secrets (DB password, INTERNAL_KEY, GUEST_SECRET); back up every config file before changing it and list the backup paths; do not restart the Minecraft server or anything with players online without telling me first; do not change anything outside what is listed.

Source: https://github.com/ruihan12/Frontline-Conquest, branch `multiplayer` (clone read-only to /home/opc/frontline-src; `git pull` for updates; never push).

1. Account service (server/accounts in the repo; README.md there has the details)
   - MariaDB: use the existing server. Create a separate database and user for the game (names of your choice), apply `schema.sql` (schema version 4), case-insensitive collation. Grant that user only SELECT, INSERT, UPDATE, DELETE on that database.
   - Python venv, `pip install -r requirements.txt`, env file `/etc/rofront/accounts.env` (root:root, 600) with DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, INTERNAL_KEY, GUEST_SECRET (generate the two secrets with `openssl rand -hex 32`).
   - systemd unit as in the README, listening on 127.0.0.1:8071. Run the tests first: `python -m pytest` in server/accounts.
2. Game server (server/deploy in the repo has the unit, env example, README and nginx block)
   - Download Godot 4.3 stable Linux arm64 (`Godot_v4.3-stable_linux.arm64.zip` from the godotengine/godot `4.3-stable` release) to /home/opc/frontline-server/bin/godot, chmod +x, check `./godot --version` prints 4.3.stable.
   - The game pack `rofront.pck` is built on my PC and I will upload it to /home/opc/frontline-server/bin/ (about 145 MB). Until it is there, stop after preparing everything else.
   - /etc/rofront/server.env from server.env.example, same INTERNAL_KEY as accounts.env, FRONTLINE_RANKED=1 FRONTLINE_SPEED_CAP=1 FRONTLINE_DEFAULT_BOTS=40 at first; install rofront-server.service; do not start it until the pck is there.
   - nginx: add the `location /ws` block from the README to the frontline.henrymc.org server (wss on 443, proxy to 127.0.0.1:8070); reload nginx after `nginx -t`.
   - Do not open port 8070 or 8071 on the firewall: both stay on 127.0.0.1.
3. Check
   - `curl -s https://frontline.henrymc.org/api/v1/guest -X POST -d '{}'` returns a Guest name.
   - After the pck is uploaded: `systemctl start rofront-server`, then `journalctl -u rofront-server -n 20` should show `MPSERVER listening on 8070` and `match started`. Watch CPU for a minute (`top -b -n1 | head`): the game server uses about one core at 40 bots. If Minecraft lags, tell me; the fix is fewer bots (FRONTLINE_DEFAULT_BOTS) or a lower nice value.
4. Report: what was installed, file paths (units, env files, backups), the service status, anything that differed from this list. No secret values.
