import hashlib
import hmac
import ipaddress
import json
import math
import re
import secrets
import sqlite3
import threading
import time
from collections import defaultdict, deque
from datetime import datetime, timezone
from uuid import UUID

from argon2 import PasswordHasher
from argon2.exceptions import VerificationError
from pymysql.err import IntegrityError

SESSION_SECONDS = 30 * 86400
CODE_SECONDS = 600
PROGRESS_LIMIT = 64 * 1024
USERNAME = re.compile(r"[A-Za-z0-9_]{3,16}", re.ASCII)
TOKEN = re.compile(r"[A-Za-z0-9_-]{43}", re.ASCII)
CODE = re.compile(r"[ABCDEFGHJKLMNPQRSTUVWXYZ]{4}-[23456789]{4}")
DUPLICATE_ERRORS = (IntegrityError, sqlite3.IntegrityError)


class ApiError(Exception):
    def __init__(self, status, code, message):
        self.status = status
        self.code = code
        self.message = message


def bad_request(message="Check the request fields and try again."):
    return ApiError(400, "bad_request", message)


def invalid_session():
    return ApiError(401, "invalid_session", "Your session is invalid or expired.")


def not_linked():
    return ApiError(404, "not_linked", "No Minecraft account is linked.")


def expired():
    return ApiError(410, "code_expired", "This code has expired. Request a new code.")


def duplicate(exc):
    return (isinstance(exc, IntegrityError) and exc.args[0] == 1062
            or isinstance(exc, sqlite3.IntegrityError)
            and exc.sqlite_errorcode in (sqlite3.SQLITE_CONSTRAINT_UNIQUE, sqlite3.SQLITE_CONSTRAINT_PRIMARYKEY))


def utc(value):
    return datetime.fromtimestamp(value, timezone.utc).replace(tzinfo=None, microsecond=0)


def iso(value):
    if value is None:
        return None
    if isinstance(value, str):
        value = datetime.fromisoformat(value)
    return value.replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def valid_password(value):
    return isinstance(value, str) and 8 <= len(value) <= 128


def progress_json(value):
    if not isinstance(value, dict):
        raise bad_request("Progress must be an object.")
    encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    if len(encoded.encode("utf-8")) > PROGRESS_LIMIT:
        raise ApiError(413, "too_large", "Progress exceeds 64 KB.")
    return encoded


def token_hash(token):
    return hashlib.sha256(token.encode("ascii")).hexdigest()


def client_ip(peer, forwarded):
    if peer == "127.0.0.1" and forwarded:
        try:
            return str(ipaddress.ip_address(forwarded.rsplit(",", 1)[-1].strip()))
        except ValueError:
            pass
    return peer


class Limits:
    def __init__(self, clock):
        self.clock = clock
        self.keys = defaultdict(deque)
        self.lock = threading.Lock()
        self.next_cleanup = 0

    def take(self, key, maximum, window=600):
        now = self.clock()
        with self.lock:
            if now >= self.next_cleanup:
                for old_key, attempts in list(self.keys.items()):
                    if not attempts or attempts[-1][0] <= now - 600:
                        del self.keys[old_key]
                self.next_cleanup = now + 60
            attempts = self.keys[key]
            while attempts and attempts[0][0] <= now - window:
                attempts.popleft()
            if len(attempts) >= maximum:
                raise ApiError(429, "rate_limited", "Too many attempts. Wait and try again.")
            ticket = (now, object())
            attempts.append(ticket)
            return ticket

    def release(self, key, ticket):
        with self.lock:
            attempts = self.keys.get(key)
            if attempts and ticket in attempts:
                attempts.remove(ticket)


def elo_changes(players, ratings):
    """Average multiplayer Elo deltas using the same pre-match ratings for every pair."""
    ranks = [(p["left_early"], p["placement"]) for p in players]
    changes = []
    for i, player in enumerate(players):
        rating = ratings[player["account_id"]]
        before = rating["elo"]
        k = 32 if rating["matches"] < 10 else 24
        pair_deltas = []
        for j, opponent in enumerate(players):
            if i == j:
                continue
            other = ratings[opponent["account_id"]]["elo"]
            expectation = 0.5 if before == other else 1 / (1 + 10 ** max(-300, min(300, (other - before) / 400)))
            outcome = 0.5 if ranks[i] == ranks[j] else float(ranks[i] < ranks[j])
            pair_deltas.append(k * (outcome - expectation))
        delta = math.fsum(pair_deltas) / len(pair_deltas) if pair_deltas else 0
        rounded = math.floor(delta + 0.5) if delta >= 0 else math.ceil(delta - 0.5)
        changes.append({"account_id": player["account_id"], "elo_before": before, "elo_after": before + rounded})
    return changes


class Service:
    def __init__(self, store, internal_key, guest_secret, clock=time.time):
        self.store = store
        self.internal_key = internal_key.encode("utf-8")
        self.guest_secret = guest_secret.encode("utf-8")
        self.clock = clock
        self.limits = Limits(clock)
        self.passwords = PasswordHasher()
        self.dummy_hash = self.passwords.hash(secrets.token_urlsafe(32))
        self.routes = {
            ("POST", "/guest"): self.guest,
            ("POST", "/register"): self.register,
            ("POST", "/login"): self.login,
            ("POST", "/logout"): self.logout,
            ("GET", "/me"): self.me,
            ("GET", "/progress"): self.get_progress,
            ("PUT", "/progress"): self.put_progress,
            ("POST", "/mc/link-code"): self.link_code,
            ("GET", "/mc/status"): self.mc_status,
            ("POST", "/mc/unlink"): self.unlink,
            ("POST", "/recover/start"): self.recover_start,
            ("GET", "/recover/status"): self.recover_status,
            ("POST", "/recover/complete"): self.recover_complete,
            ("GET", "/leaderboard"): self.leaderboard,
            ("GET", "/rating"): self.rating,
            ("POST", "/internal/verify-session"): self.verify_session,
            ("POST", "/internal/mc-confirm"): self.mc_confirm,
            ("POST", "/internal/match-result"): self.match_result,
        }

    def dispatch(self, method, path, body, query, headers, peer):
        if path.startswith("/internal/"):
            supplied = headers.get("X-Internal-Key", "").encode("utf-8")
            if peer != "127.0.0.1" or not hmac.compare_digest(supplied, self.internal_key):
                raise ApiError(403, "forbidden", "This endpoint is internal.")
        handler = self.routes.get((method, path))
        if not handler:
            raise ApiError(404, "not_found", "Unknown endpoint.")
        authorization = headers.get("Authorization", "")
        token = authorization[7:] if authorization.startswith("Bearer ") else ""
        ip = client_ip(peer, headers.get("X-Forwarded-For"))
        return handler(body, query, token, ip)

    def _issue(self, db, account_id, username):
        token = secrets.token_urlsafe(32)
        now = self.clock()
        db.execute("INSERT INTO sessions (token_hash, account_id, expires_at) VALUES (%s,%s,%s)",
                   token_hash(token), account_id, utc(now + SESSION_SECONDS))
        return {"token": token, "account_id": account_id, "username": username, "expires_in": SESSION_SECONDS}

    def _account(self, db, token):
        if not isinstance(token, str) or not TOKEN.fullmatch(token):
            raise invalid_session()
        row = db.one("SELECT a.id AS account_id, a.username FROM sessions s JOIN accounts a "
                     "ON a.id=s.account_id WHERE s.token_hash=%s AND s.expires_at>%s",
                     token_hash(token), utc(self.clock()))
        if row is None:
            raise invalid_session()
        return row

    def _lock_account(self, db, aid):
        db.one("SELECT id FROM accounts WHERE id=%s FOR UPDATE", aid)

    def _write_progress(self, db, aid, encoded):
        now = utc(self.clock())
        if db.one("SELECT account_id FROM progress WHERE account_id=%s FOR UPDATE", aid):
            db.execute("UPDATE progress SET data=%s,updated_at=%s WHERE account_id=%s", encoded, now, aid)
        else:
            db.execute("INSERT INTO progress (account_id,data,updated_at) VALUES (%s,%s,%s)", aid, encoded, now)
        return {"updated_at": iso(now)}

    def _code(self, db, aid, kind):
        db.execute("UPDATE link_codes SET consumed=1 WHERE account_id=%s AND kind=%s AND consumed=0", aid, kind)
        for _ in range(8):
            letters = "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ") for _ in range(4))
            digits = "".join(secrets.choice("23456789") for _ in range(4))
            code = letters + "-" + digits
            try:
                db.execute("INSERT INTO link_codes (code,account_id,kind,expires_at) VALUES (%s,%s,%s,%s)",
                           code, aid, kind, utc(self.clock() + CODE_SECONDS))
            except DUPLICATE_ERRORS as exc:
                if not duplicate(exc):
                    raise
                continue
            return {"code": code, "expires_in": CODE_SECONDS}
        raise ApiError(503, "try_again", "Please try again.")

    def _code_row(self, db, code, *, lock=False):
        if not isinstance(code, str) or not CODE.fullmatch(code):
            return None
        suffix = " FOR UPDATE" if lock else ""
        return db.one("SELECT account_id,kind,used,consumed,expires_at FROM link_codes WHERE code=%s" + suffix, code)

    def _active(self, row):
        if row is None or row["consumed"]:
            return False
        expiry = row["expires_at"]
        if isinstance(expiry, str):
            expiry = datetime.fromisoformat(expiry)
        return expiry > utc(self.clock())

    def _sign(self, payload):
        return hmac.new(self.guest_secret, payload.encode("ascii"), hashlib.sha256).hexdigest()

    def guest(self, body, query, token, ip):
        with self.store.transaction() as db:
            counter = db.execute("INSERT INTO guest_counter (issued_at) VALUES (%s)", utc(self.clock()))
        name = f"Guest_{counter:04d}"
        payload = f"guest.{name}.{int(self.clock()) + SESSION_SECONDS}.{secrets.token_urlsafe(32)}"
        return {"name": name, "token": payload + "." + self._sign(payload)}

    def register(self, body, query, token, ip):
        self.limits.take(("register", ip), 5)
        username, password = body.get("username"), body.get("password")
        if (not isinstance(username, str) or not USERNAME.fullmatch(username)
                or username.lower().startswith("guest_") or not valid_password(password)):
            raise bad_request("Use a valid username and an 8–128 character password. Guest_ names are reserved.")
        encoded = progress_json(body["progress"]) if "progress" in body else None
        hashed = self.passwords.hash(password)
        try:
            with self.store.transaction() as db:
                aid = db.execute("INSERT INTO accounts (username,pass_hash) VALUES (%s,%s)", username, hashed)
                db.execute("INSERT INTO ratings (account_id) VALUES (%s)", aid)
                if encoded is not None:
                    self._write_progress(db, aid, encoded)
                return self._issue(db, aid, username)
        except DUPLICATE_ERRORS as exc:
            if not duplicate(exc):
                raise
            raise ApiError(409, "username_taken", "That username is already taken.") from None

    def login(self, body, query, token, ip):
        username, password = body.get("username"), body.get("password")
        key = ("login", ip, username.lower()[:24] if isinstance(username, str) else "")
        ticket = self.limits.take(key, 5)
        with self.store.transaction() as db:
            row = db.one("SELECT id,username,pass_hash FROM accounts WHERE username=%s", username) if isinstance(username, str) and USERNAME.fullmatch(username) else None
        hashed = row["pass_hash"] if row else self.dummy_hash
        valid = False
        if valid_password(password):
            try:
                valid = self.passwords.verify(hashed, password)
            except VerificationError:
                pass
        if not (row and valid):
            raise ApiError(401, "invalid_credentials", "The username or password is incorrect.")
        with self.store.transaction() as db:
            current = db.one("SELECT pass_hash FROM accounts WHERE id=%s FOR UPDATE", row["id"])
            if not current or not hmac.compare_digest(hashed, current["pass_hash"]):
                raise ApiError(401, "invalid_credentials", "The username or password is incorrect.")
            db.execute("UPDATE accounts SET last_login=%s,pass_hash=%s WHERE id=%s", utc(self.clock()),
                       self.passwords.hash(password) if self.passwords.check_needs_rehash(hashed) else hashed, row["id"])
            response = self._issue(db, row["id"], row["username"])
        self.limits.release(key, ticket)
        return response

    def logout(self, body, query, token, ip):
        with self.store.transaction() as db:
            self._account(db, token)
            db.execute("DELETE FROM sessions WHERE token_hash=%s", token_hash(token))
        return {}

    def me(self, body, query, token, ip):
        with self.store.transaction() as db:
            account = self._account(db, token)
            aid = account["account_id"]
            rating = db.one("SELECT elo,matches FROM ratings WHERE account_id=%s", aid)
            linked = db.one("SELECT account_id FROM mc_links WHERE account_id=%s", aid)
        return {**account, **rating, "mc_linked": linked is not None}

    def get_progress(self, body, query, token, ip):
        with self.store.transaction() as db:
            aid = self._account(db, token)["account_id"]
            row = db.one("SELECT data,updated_at FROM progress WHERE account_id=%s", aid)
        return {"data": json.loads(row["data"]), "updated_at": iso(row["updated_at"])} if row else {"data": {}, "updated_at": None}

    def put_progress(self, body, query, token, ip):
        with self.store.transaction() as db:
            aid = self._account(db, token)["account_id"]
            self._lock_account(db, aid)
            return self._write_progress(db, aid, progress_json(body.get("data")))

    def link_code(self, body, query, token, ip):
        with self.store.transaction() as db:
            aid = self._account(db, token)["account_id"]
            self.limits.take(("link", aid), 5)
            self._lock_account(db, aid)
            if db.one("SELECT account_id FROM mc_links WHERE account_id=%s FOR UPDATE", aid):
                raise ApiError(409, "already_linked", "Minecraft is already linked.")
            return self._code(db, aid, "link")

    def mc_status(self, body, query, token, ip):
        with self.store.transaction() as db:
            aid = self._account(db, token)["account_id"]
            return {"linked": db.one("SELECT account_id FROM mc_links WHERE account_id=%s", aid) is not None}

    def unlink(self, body, query, token, ip):
        with self.store.transaction() as db:
            aid = self._account(db, token)["account_id"]
            self._lock_account(db, aid)
            if not db.one("SELECT account_id FROM mc_links WHERE account_id=%s FOR UPDATE", aid):
                raise not_linked()
            db.execute("DELETE FROM mc_links WHERE account_id=%s", aid)
            db.execute("UPDATE link_codes SET consumed=1 WHERE account_id=%s AND consumed=0", aid)
        return {}

    def recover_start(self, body, query, token, ip):
        self.limits.take(("recover", ip), 5)
        username = body.get("username")
        if not isinstance(username, str) or not USERNAME.fullmatch(username):
            raise not_linked()
        with self.store.transaction() as db:
            account = db.one("SELECT id FROM accounts WHERE username=%s FOR UPDATE", username)
            if not account or not db.one("SELECT account_id FROM mc_links WHERE account_id=%s FOR UPDATE", account["id"]):
                raise not_linked()
            return self._code(db, account["id"], "recover")

    def recover_status(self, body, query, token, ip):
        with self.store.transaction() as db:
            row = self._code_row(db, query.get("code"))
        state = "expired"
        if self._active(row) and row["kind"] == "recover":
            state = "confirmed" if row["used"] else "pending"
        return {"state": state}

    def recover_complete(self, body, query, token, ip):
        code, password = body.get("code"), body.get("new_password")
        if not isinstance(code, str) or not CODE.fullmatch(code) or not valid_password(password):
            raise bad_request()
        with self.store.transaction() as db:
            row = self._code_row(db, code)
            self._require_recovery(row)
        hashed = self.passwords.hash(password)
        with self.store.transaction() as db:
            aid = row["account_id"]
            self._lock_account(db, aid)
            self._require_recovery(self._code_row(db, code, lock=True))
            db.execute("UPDATE accounts SET pass_hash=%s WHERE id=%s", hashed, aid)
            db.execute("DELETE FROM sessions WHERE account_id=%s", aid)
            db.execute("UPDATE link_codes SET consumed=1 WHERE account_id=%s AND consumed=0", aid)
        return {}

    def _require_recovery(self, row):
        if not self._active(row) or row["kind"] != "recover":
            raise expired()
        if not row["used"]:
            raise ApiError(403, "not_confirmed", "Confirm this code in Minecraft first.")

    def leaderboard(self, body, query, token, ip):
        try:
            limit = max(1, min(100, int(query.get("limit", "50"))))
        except ValueError:
            raise bad_request() from None
        with self.store.transaction() as db:
            return {"players": db.all("SELECT a.username,r.elo,r.matches FROM ratings r "
                                      "JOIN accounts a ON a.id=r.account_id ORDER BY r.elo DESC,a.id LIMIT %s", limit)}

    def rating(self, body, query, token, ip):
        with self.store.transaction() as db:
            aid = self._account(db, token)["account_id"]
            return db.one("SELECT elo,matches,wins FROM ratings WHERE account_id=%s", aid)

    def verify_session(self, body, query, token, ip):
        token = body.get("token")
        if isinstance(token, str) and len(token) <= 200:
            parts = token.split(".")
            if len(parts) == 5 and parts[0] == "guest":
                _, name, expiry, nonce, signature = parts
                if (re.fullmatch(r"Guest_[0-9]{4,10}", name) and re.fullmatch(r"[0-9]{1,12}", expiry)
                        and TOKEN.fullmatch(nonce) and re.fullmatch(r"[0-9a-f]{64}", signature)
                        and hmac.compare_digest(signature, self._sign(".".join(parts[:-1])))
                        and int(expiry) > self.clock()):
                    return {"guest": True, "name": name}
                raise invalid_session()
        with self.store.transaction() as db:
            return {**self._account(db, token), "guest": False}

    def mc_confirm(self, body, query, token, ip):
        code = body.get("code")
        try:
            uuid = str(UUID(body.get("mc_uuid")))
        except (ValueError, AttributeError, TypeError):
            raise bad_request("Invalid Minecraft UUID.") from None
        try:
            with self.store.transaction() as db:
                row = self._code_row(db, code)
                if row is None:
                    raise ApiError(404, "unknown_code", "That code was not found.")
                aid = row["account_id"]
                self._lock_account(db, aid)
                row = self._code_row(db, code, lock=True)
                if not self._active(row):
                    raise expired()
                if row["kind"] == "link":
                    db.execute("INSERT INTO mc_links (account_id,mc_uuid) VALUES (%s,%s)", aid, uuid)
                    db.execute("UPDATE link_codes SET used=1,consumed=1 WHERE code=%s", code)
                else:
                    link = db.one("SELECT mc_uuid FROM mc_links WHERE account_id=%s FOR UPDATE", aid)
                    if not link or not hmac.compare_digest(link["mc_uuid"], uuid):
                        raise ApiError(403, "wrong_player", "Use the Minecraft account linked to this game account.")
                    db.execute("UPDATE link_codes SET used=1 WHERE code=%s", code)
                return {"kind": row["kind"]}
        except DUPLICATE_ERRORS as exc:
            if not duplicate(exc):
                raise
            raise ApiError(409, "already_linked", "The Minecraft or game account is already linked.") from None

    def match_result(self, body, query, token, ip):
        ranked, map_name, players = body.get("ranked"), body.get("map"), body.get("players")
        if (type(ranked) is not bool or not isinstance(map_name, str) or not 1 <= len(map_name) <= 64
                or not isinstance(players, list) or not 1 <= len(players) <= 100):
            raise bad_request()
        dates = []
        for key in ("started_at", "ended_at"):
            try:
                parsed = datetime.fromisoformat(body.get(key))
                if parsed.tzinfo is None:
                    raise ValueError()
                dates.append(parsed.astimezone(timezone.utc).replace(tzinfo=None, microsecond=0))
            except (ValueError, TypeError, OverflowError):
                raise bad_request("Supply ISO8601 times with a timezone.") from None
        if dates[0] > dates[1]:
            raise bad_request("The match must end after it starts.")
        ids = set()
        for player in players:
            if not isinstance(player, dict):
                raise bad_request()
            aid, placement, seconds, share, early = (player.get(key) for key in
                ("account_id", "placement", "survival_secs", "tile_share", "left_early"))
            if (type(aid) is not int or not 0 < aid < 2**64 or aid in ids
                    or type(placement) is not int or not 0 < placement < 2**31
                    or type(seconds) is not int or not 0 <= seconds < 2**31
                    or type(share) not in (int, float) or not 0 <= share <= 1 or type(early) is not bool):
                raise bad_request()
            ids.add(aid)
        with self.store.transaction() as db:
            ratings = {}
            for aid in sorted(ids):
                row = db.one("SELECT elo,matches FROM ratings WHERE account_id=%s FOR UPDATE", aid)
                if not row:
                    raise bad_request("A match player does not have an account.")
                ratings[aid] = row
            changes = elo_changes(players, ratings) if ranked else [
                {"account_id": p["account_id"], "elo_before": ratings[p["account_id"]]["elo"],
                 "elo_after": ratings[p["account_id"]]["elo"]} for p in players]
            mid = db.execute("INSERT INTO matches (ranked,map,started_at,ended_at) VALUES (%s,%s,%s,%s)",
                             ranked, map_name, *dates)
            for player, change in zip(players, changes):
                aid = player["account_id"]
                db.execute("INSERT INTO match_players (match_id,account_id,placement,survival_secs,tile_share,"
                           "left_early,elo_before,elo_after) VALUES (%s,%s,%s,%s,%s,%s,%s,%s)",
                           mid, aid, player["placement"], player["survival_secs"], player["tile_share"],
                           player["left_early"], change["elo_before"], change["elo_after"])
                if ranked:
                    db.execute("UPDATE ratings SET elo=%s,matches=matches+1,wins=wins+%s WHERE account_id=%s",
                               change["elo_after"], int(player["placement"] == 1), aid)
        return {"match_id": mid, "changes": changes}
