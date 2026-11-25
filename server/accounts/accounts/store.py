"""Transaction and query helpers shared by MariaDB and the SQLite tests."""
from contextlib import contextmanager
from datetime import datetime

import pymysql


class Queries:
    def __init__(self, cursor, sqlite):
        self.cursor = cursor
        self.sqlite = sqlite

    def execute(self, sql, *args):
        if self.sqlite:
            sql = sql.replace("%s", "?").replace(" FOR UPDATE", "")
            args = tuple(value.isoformat(" ") if isinstance(value, datetime) else value for value in args)
        self.cursor.execute(sql, args)
        return self.cursor.lastrowid

    def one(self, sql, *args):
        self.execute(sql, *args)
        row = self.cursor.fetchone()
        return dict(row) if row is not None else None

    def all(self, sql, *args):
        self.execute(sql, *args)
        return [dict(row) for row in self.cursor.fetchall()]


class Store:
    def __init__(self, connect, *, sqlite=False):
        self.connect = connect
        self.sqlite = sqlite

    @contextmanager
    def transaction(self):
        conn = self.connect()
        try:
            if self.sqlite:
                conn.execute("BEGIN IMMEDIATE")
            cursor = conn.cursor()
            try:
                yield Queries(cursor, self.sqlite)
            finally:
                cursor.close()
            conn.commit()
        except BaseException:
            conn.rollback()
            raise
        finally:
            conn.close()


def mariadb(env):
    return Store(lambda: pymysql.connect(
        host=env["DB_HOST"], port=int(env["DB_PORT"]),
        database=env["DB_NAME"], user=env["DB_USER"], password=env["DB_PASSWORD"],
        charset="utf8mb4", cursorclass=pymysql.cursors.DictCursor,
        init_command="SET time_zone = '+00:00'", connect_timeout=5,
        read_timeout=15, write_timeout=15,
    ))
