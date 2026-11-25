# RoFront account service

Use Python 3.11 or later and MariaDB. Apply `schema.sql` once using a database administrator.
Give the service account SELECT, INSERT, UPDATE and DELETE on the accounts database. Use
a case-insensitive collation for the database so usernames are unique regardless of case.
From this directory, install requirements with `python -m pip install -r requirements.txt`
and run `python -m accounts`. The service checks schema version 5 before listening on
`127.0.0.1:8071` and handles the full `/api/v1/` path.

Set all of these environment variables:

- `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` for MariaDB.
- `INTERNAL_KEY` shared with the local game and Minecraft servers.
- `GUEST_SECRET` for HMAC guest-token signing. Generate independent high-entropy values for both secrets.

Store the environment file outside this checkout, owned by root with mode 600.
Run under an existing unprivileged service user:

```ini
[Unit]
Description=RoFront account API
After=network.target mariadb.service

[Service]
User=rofront
Group=rofront
WorkingDirectory=/srv/rofront/server/accounts
EnvironmentFile=/etc/rofront/accounts.env
ExecStart=/srv/rofront/venv/bin/python -m accounts
Nice=10
CPUWeight=25
NoNewPrivileges=yes
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

In the HTTPS virtual host:

```nginx
location ^~ /api/v1/internal/ {
    return 403;
}

location ^~ /api/v1/ {
    access_log off;
    client_max_body_size 128k;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Internal-Key "";
    proxy_pass http://127.0.0.1:8071;
}
```

The API reads only the last forwarded address and only if the TCP peer is loopback.
Nginx replaces the incoming header. If using Cloudflare, configure nginx's real-IP
module to accept CF-Connecting-IP only from Cloudflare's published proxy ranges, so
`$remote_addr` is the verified client address. Internal endpoints use the raw TCP
peer and the key. Keep port 8071 bound to loopback. Disable logging of request bodies,
authorization headers and URLs under this prefix at all proxy layers.

Rate limits use ten-minute windows in one service process. Registration and recovery
start allow five attempts per IP, and link-code generation allows five per account.
Login allows five failures per IP and normalized username. Sessions and guest tokens
expire in 30 days. Generating a fresh Minecraft code replaces any outstanding code of
the same kind. Match results have no replay identifier in this API, so submit each
completed match once.

Run tests with `python -m pip install pytest` and `python -m pytest` from this directory.
The suite uses SQLite by default. To test MariaDB, set the DB variables for a disposable
empty database, apply `schema.sql`, then set `TEST_MARIADB=1`. The suite clears test
database tables between cases. Only enable this on a disposable database.

Reapply `schema.sql` to migrate a version 4 database. The migration keeps prior
match history; `GET /api/v1/history?limit=20` returns the authenticated player's
latest matches with a nullable team number. Older rows have no recorded team.
