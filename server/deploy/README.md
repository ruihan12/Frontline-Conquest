# Game server deploy (Oracle VM, aarch64)

One process runs one match at a time (the sim is single-threaded). When a match ends the end screen stays 25 s,
every player is disconnected, and the next match starts. Ranked matches report their result to the account
service (`/internal/match-result`) and send each player their placement and Elo change.

## Files
- `bin/godot`: Godot 4.3 stable, Linux arm64 (download `Godot_v4.3-stable_linux.arm64.zip` from the godotengine/godot
  4.3-stable release, unzip, rename, `chmod +x`). Must be exactly 4.3 to read the pack.
- `bin/rofront.pck`: built on the dev machine with `godot --headless --path . --export-pack "Server Pack" rofront.pck`
  (preset "Server Pack" in export_presets.cfg; about 145 MB). It is platform-independent, so the x86 build runs on arm64.
- `/etc/rofront/server.env` from `server.env.example`; `rofront-server.service` into `/etc/systemd/system/`.

## Steps
```
sudo install -d -m 700 /etc/rofront
sudo cp server.env.example /etc/rofront/server.env && sudo chmod 600 /etc/rofront/server.env   # then fill INTERNAL_KEY
sudo cp rofront-server.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now rofront-server
journalctl -u rofront-server -f      # expect: MPSERVER listening on 8070 / match started
```
Tell the players before restarting while a match is running (it ends the match for everyone).

## nginx (frontline.henrymc.org)
```
location /ws {
    proxy_pass http://127.0.0.1:8070;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 3600s;
    proxy_buffer_size 1m;
}
```
Clients connect to `wss://frontline.henrymc.org/ws`. A client can override it with `save.settings.server_url`.

## Quick local check (no VM)
```
godot --headless --path . -- --server --port=8070 --bots=40 --netlog        # server
godot --headless --path . -- --connect=ws://127.0.0.1:8070 --name=Bob --netlog --autospawn   # a viewer
```
Command-line flags: `--server --port= --bots= --map=tab:index --max= --enet`, `--hostlocal` (a player PC host over ENet),
`--connect=url [--enet] --name= --token= --autospawn --netlog`.
