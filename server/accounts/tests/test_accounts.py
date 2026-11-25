import json
import os
import sqlite3
import threading
from http.client import HTTPConnection

import pytest

from accounts.__main__ import Handler, Server
from accounts.service import ApiError, Service, elo_changes
from accounts.store import Store, mariadb

KEY = "pytest internal fixture"
GUEST_SECRET = "pytest guest fixture"
PASSWORD = "test-only-password"
UUID = "8a9f3186-a30e-4f1a-9a02-e4464a289143"
OTHER_UUID = "35684d72-084d-4fa5-8297-e9139880c879"

SQLITE_SCHEMA = """
CREATE TABLE accounts (id INTEGER PRIMARY KEY, username TEXT COLLATE NOCASE UNIQUE, pass_hash TEXT, last_login DATETIME);
CREATE TABLE sessions (token_hash TEXT PRIMARY KEY, account_id INTEGER, expires_at DATETIME);
CREATE TABLE ratings (account_id INTEGER PRIMARY KEY, elo INTEGER DEFAULT 1000, matches INTEGER DEFAULT 0, wins INTEGER DEFAULT 0);
CREATE TABLE progress (account_id INTEGER PRIMARY KEY, data TEXT, updated_at DATETIME);
CREATE TABLE mc_links (account_id INTEGER PRIMARY KEY, mc_uuid TEXT UNIQUE);
CREATE TABLE link_codes (code TEXT PRIMARY KEY, account_id INTEGER, kind TEXT, expires_at DATETIME, used INTEGER DEFAULT 0, consumed INTEGER DEFAULT 0);
CREATE TABLE guest_counter (id INTEGER PRIMARY KEY AUTOINCREMENT, issued_at DATETIME);
CREATE TABLE matches (id INTEGER PRIMARY KEY, ranked INTEGER, map TEXT, started_at DATETIME, ended_at DATETIME);
CREATE TABLE match_players (match_id INTEGER, account_id INTEGER, placement INTEGER, survival_secs INTEGER, tile_share REAL, left_early INTEGER, elo_before INTEGER, elo_after INTEGER);
"""


@pytest.fixture
def clock():
    value = [1_780_000_000.0]
    return value


@pytest.fixture
def service(tmp_path, clock):
    if os.environ.get("TEST_MARIADB") == "1":
        store = mariadb(os.environ)
        with store.transaction() as db:
            for table in ("match_players", "matches", "sessions", "progress", "link_codes", "mc_links", "ratings", "accounts", "guest_counter"):
                db.execute("DELETE FROM " + table)
            db.execute("ALTER TABLE guest_counter AUTO_INCREMENT=1")
    else:
        path = tmp_path / "accounts.db"

        def connect():
            connection = sqlite3.connect(path)
            connection.row_factory = sqlite3.Row
            return connection

        with connect() as database:
            database.executescript(SQLITE_SCHEMA)
        store = Store(connect, sqlite=True)
    return Service(store, KEY, GUEST_SECRET, lambda: clock[0])


def call(service, method, path, body=None, *, token="", key=None, query=None, forwarded="198.51.100.5", peer="127.0.0.1"):
    headers = {"Authorization": "Bearer " + token, "X-Forwarded-For": forwarded}
    if key is not None:
        headers["X-Internal-Key"] = key
    return service.dispatch(method, path, body or {}, query or {}, headers, peer)


def error(status, code, action, *args, **kwargs):
    with pytest.raises(ApiError) as result:
        action(*args, **kwargs)
    assert (result.value.status, result.value.code) == (status, code)


def signup(service, username="Player_1", **extra):
    return call(service, "POST", "/register", {"username": username, "password": PASSWORD, **extra})


def test_registration_login_logout(service):
    error(400, "bad_request", signup, service, "gUeSt_001")
    account = signup(service, progress={"stars": 123})
    token = account["token"]
    aid = account["account_id"]
    assert account["expires_in"] == 2592000
    with service.store.transaction() as db:
        assert db.one("SELECT pass_hash FROM accounts WHERE id=%s", aid)["pass_hash"].startswith("$argon2id$")
        assert db.one("SELECT token_hash FROM sessions WHERE account_id=%s", aid)["token_hash"] != token
    error(409, "username_taken", signup, service, "player_1")
    assert call(service, "GET", "/me", token=token) == {
        "account_id": aid, "username": "Player_1", "elo": 1000, "matches": 0, "mc_linked": False,
    }
    signed_in = call(service, "POST", "/login", {"username": "PLAYER_1", "password": PASSWORD})
    assert signed_in["token"] != token
    assert call(service, "POST", "/logout", token=token) == {}
    error(401, "invalid_session", call, service, "GET", "/me", token=token)
    assert call(service, "GET", "/rating", token=signed_in["token"])["wins"] == 0


def test_rate_limits_and_proxy_hop(service, clock):
    for i in range(5):
        error(401, "invalid_credentials", call, service, "POST", "/login",
              {"username": "Example", "password": PASSWORD}, forwarded=f"192.0.2.{i + 1}, 198.51.100.5")
    error(429, "rate_limited", call, service, "POST", "/login", {"username": "example", "password": PASSWORD})
    error(401, "invalid_credentials", call, service, "POST", "/login", {"username": "Another", "password": PASSWORD})
    clock[0] += 600
    error(401, "invalid_credentials", call, service, "POST", "/login", {"username": "Example", "password": PASSWORD})
    token = signup(service)["token"]
    for _ in range(5):
        call(service, "POST", "/mc/link-code", token=token)
        error(404, "not_linked", call, service, "POST", "/recover/start", {"username": "Unknown"})
    error(429, "rate_limited", call, service, "POST", "/mc/link-code", token=token)
    error(429, "rate_limited", call, service, "POST", "/recover/start", {"username": "Unknown"})
    for index in range(4):
        error(400, "bad_request", signup, service, f"Guest_{index}")
    error(429, "rate_limited", signup, service, "Player_2")


def test_progress(service):
    token = signup(service)["token"]
    assert call(service, "GET", "/progress", token=token) == {"data": {}, "updated_at": None}
    original = {"stars": 5000}
    saved = call(service, "PUT", "/progress", {"data": original}, token=token)
    assert call(service, "GET", "/progress", token=token) == {"data": original, **saved}
    error(413, "too_large", call, service, "PUT", "/progress", {"data": {"v": "é" * 32768}}, token=token)
    assert call(service, "GET", "/progress", token=token)["data"] == original


def test_guest_verify(service, clock):
    guest = call(service, "POST", "/guest")
    assert guest["name"] == "Guest_0001"
    assert call(service, "POST", "/guest")["name"] == "Guest_0002"
    body = {"token": guest["token"]}
    error(403, "forbidden", call, service, "POST", "/internal/verify-session", body)
    error(403, "forbidden", call, service, "POST", "/internal/verify-session", body, key="wrong")
    error(403, "forbidden", call, service, "POST", "/internal/verify-session", body, key=KEY, peer="198.51.100.5")
    assert call(service, "POST", "/internal/verify-session", body, key=KEY) == {"guest": True, "name": "Guest_0001"}
    forged = guest["token"].replace("0001", "0002", 1)
    error(401, "invalid_session", call, service, "POST", "/internal/verify-session", {"token": forged}, key=KEY)
    clock[0] += 2592000
    error(401, "invalid_session", call, service, "POST", "/internal/verify-session", body, key=KEY)


def test_link_and_recover(service, clock):
    token = signup(service)["token"]
    error(404, "not_linked", call, service, "POST", "/recover/start", {"username": "Player_1"})
    link = call(service, "POST", "/mc/link-code", token=token)["code"]
    error(404, "unknown_code", call, service, "POST", "/internal/mc-confirm", {"code": "?", "mc_uuid": UUID}, key=KEY)
    clock[0] += 600
    error(410, "code_expired", call, service, "POST", "/internal/mc-confirm", {"code": link, "mc_uuid": UUID}, key=KEY)
    link = call(service, "POST", "/mc/link-code", token=token)["code"]
    assert call(service, "POST", "/internal/mc-confirm", {"code": link, "mc_uuid": UUID}, key=KEY) == {"kind": "link"}
    assert call(service, "GET", "/mc/status", token=token) == {"linked": True}
    error(409, "already_linked", call, service, "POST", "/mc/link-code", token=token)
    other = signup(service, "Player_2")["token"]
    other_link = call(service, "POST", "/mc/link-code", token=other)["code"]
    error(409, "already_linked", call, service, "POST", "/internal/mc-confirm",
          {"code": other_link, "mc_uuid": UUID}, key=KEY)
    recovery = call(service, "POST", "/recover/start", {"username": "Player_1"})["code"]
    status = lambda: call(service, "GET", "/recover/status", query={"code": recovery})["state"]
    assert status() == "pending"
    reset = {"code": recovery, "new_password": "fixture-new-password"}
    error(403, "not_confirmed", call, service, "POST", "/recover/complete", reset)
    error(403, "wrong_player", call, service, "POST", "/internal/mc-confirm", {"code": recovery, "mc_uuid": OTHER_UUID}, key=KEY)
    assert call(service, "POST", "/internal/mc-confirm", {"code": recovery, "mc_uuid": UUID}, key=KEY) == {"kind": "recover"}
    assert status() == "confirmed"
    second = call(service, "POST", "/login", {"username": "Player_1", "password": PASSWORD})["token"]
    assert call(service, "POST", "/recover/complete", reset) == {}
    assert status() == "expired"
    error(410, "code_expired", call, service, "POST", "/recover/complete", reset)
    for prior in (token, second):
        error(401, "invalid_session", call, service, "GET", "/me", token=prior)
    current = call(service, "POST", "/login", {"username": "Player_1", "password": reset["new_password"]})["token"]
    assert call(service, "POST", "/mc/unlink", token=current) == {}
    error(404, "not_linked", call, service, "POST", "/mc/unlink", token=current)


@pytest.mark.parametrize("placements,early,played,expected", [
    ([1, 2], [False, False], [0, 0], [1016, 984]),
    ([1, 2, 3], [False] * 3, [0] * 3, [1016, 1000, 984]),
    ([1, 1], [False] * 2, [0] * 2, [1000, 1000]),
    ([1, 2], [True, False], [0] * 2, [984, 1016]),
    ([1, 2], [False] * 2, [9, 10], [1016, 988]),
])
def test_elo(placements, early, played, expected):
    players = [{"account_id": i, "placement": p, "left_early": early[i]} for i, p in enumerate(placements)]
    ratings = {i: {"elo": 1000, "matches": n} for i, n in enumerate(played)}
    assert [line["elo_after"] for line in elo_changes(players, ratings)] == expected


def test_match_transaction(service):
    first = signup(service)
    second = signup(service, "Player_2")
    body = {"ranked": True, "map": "World", "started_at": "2026-11-24T12:00:00Z",
            "ended_at": "2026-11-24T12:30:00Z", "players": [
                {"account_id": a["account_id"], "placement": i, "survival_secs": 1800,
                 "tile_share": 0.81 if i == 1 else 0.19, "left_early": False}
                for i, a in enumerate((first, second), 1)]}
    result = call(service, "POST", "/internal/match-result", body, key=KEY)
    assert [x["elo_after"] for x in result["changes"]] == [1016, 984]
    body["ranked"] = False
    result = call(service, "POST", "/internal/match-result", body, key=KEY)
    assert all(x["elo_before"] == x["elo_after"] for x in result["changes"])
    assert call(service, "GET", "/rating", token=first["token"]) == {"elo": 1016, "matches": 1, "wins": 1}
    assert call(service, "GET", "/leaderboard", query={"limit": "1"}) == {
        "players": [{"username": "Player_1", "elo": 1016, "matches": 1}]}
    body["players"][1]["account_id"] = 9999
    error(400, "bad_request", call, service, "POST", "/internal/match-result", body, key=KEY)
    with service.store.transaction() as db:
        assert db.one("SELECT COUNT(*) AS total FROM matches")["total"] == 2
        assert db.one("SELECT COUNT(*) AS total FROM match_players")["total"] == 4


def test_http_transport(service):
    with Server(("127.0.0.1", 0), Handler) as server:
        server.service = service
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        try:
            connection = HTTPConnection(*server.server_address, timeout=3)
            connection.request("POST", "/api/v1/guest", "{}")
            response = connection.getresponse()
            assert (response.status, json.load(response)["name"]) == (200, "Guest_0001")
            connection.request("POST", "/api/v1/guest", headers={"Content-Length": "131073"})
            response = connection.getresponse()
            assert (response.status, json.load(response)["error"]) == (413, "too_large")
            connection.close()
        finally:
            server.shutdown()
            thread.join()


def test_team_elo():
    from accounts.service import team_elo_changes
    # 2v2, equal ratings: the winners gain 16, the losers lose 16
    players = [{"account_id": i, "team": 1 if i < 3 else 2, "placement": 1 if i < 3 else 2, "left_early": False} for i in (1, 2, 3, 4)]
    ratings = {i: {"elo": 1000, "matches": 20 if i < 3 else 20} for i in (1, 2, 3, 4)}
    out = {c["account_id"]: c["elo_after"] for c in team_elo_changes(players, ratings)}
    assert out == {1: 1012, 2: 1012, 3: 988, 4: 988}
    # a stronger winning team gains less than an even one would
    ratings = {1: {"elo": 1400, "matches": 20}, 2: {"elo": 1400, "matches": 20}, 3: {"elo": 1000, "matches": 20}, 4: {"elo": 1000, "matches": 20}}
    out = {c["account_id"]: c["elo_after"] - ratings[c["account_id"]]["elo"] for c in team_elo_changes(players, ratings)}
    assert 0 < out[1] < 12 and out[3] < 0 and out[1] == out[2]
    # a leaver on the winning team still loses, the rest of the team wins
    players[1]["left_early"] = True
    out = {c["account_id"]: c["elo_after"] for c in team_elo_changes(players, {i: {"elo": 1000, "matches": 20} for i in (1, 2, 3, 4)})}
    assert out[1] == 1012 and out[2] < 1000


def test_team_match_needs_teams(service):
    first = signup(service)
    second = signup(service, "Player_2")
    body = {"ranked": True, "team_mode": True, "map": "World", "started_at": "2026-11-24T12:00:00Z",
            "ended_at": "2026-11-24T12:30:00Z", "players": [
                {"account_id": a["account_id"], "placement": i, "survival_secs": 1800, "tile_share": 0.4,
                 "left_early": False} for i, a in enumerate((first, second), 1)]}
    with pytest.raises(ApiError):
        call(service, "POST", "/internal/match-result", body, key=KEY)
    for i, pl in enumerate(body["players"], 1):
        pl["team"] = i
    result = call(service, "POST", "/internal/match-result", body, key=KEY)
    assert [x["elo_after"] for x in result["changes"]] == [1016, 984]
