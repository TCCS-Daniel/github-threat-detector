import psycopg2
from psycopg2 import pool
from psycopg2.extras import RealDictCursor
from contextlib import contextmanager
import os

from config import DATABASE_URL

_pool: pool.SimpleConnectionPool | None = None


def get_pool() -> pool.SimpleConnectionPool:
    global _pool
    if _pool is None:
        _pool = pool.SimpleConnectionPool(1, 10, DATABASE_URL)
    return _pool


@contextmanager
def get_conn():
    p = get_pool()
    conn = p.getconn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        p.putconn(conn)


@contextmanager
def get_cursor(dict_cursor: bool = False):
    with get_conn() as conn:
        factory = RealDictCursor if dict_cursor else None
        cur = conn.cursor(cursor_factory=factory)
        try:
            yield cur
        finally:
            cur.close()


def _read_sql(filename: str) -> str:
    path = os.path.join(os.path.dirname(__file__), filename)
    with open(path) as f:
        return f.read()


def reset_db() -> None:
    with get_cursor() as cur:
        cur.execute(_read_sql("reset.sql"))


def apply_schema() -> None:
    with get_cursor() as cur:
        cur.execute(_read_sql("schema.sql"))
