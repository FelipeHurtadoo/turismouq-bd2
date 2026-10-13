"""
Conexión a Oracle para la interfaz de TurismoUQ.

Usa python-oracledb en modo "thin" (puro Python, sin Oracle Instant Client
instalado en la máquina) contra el mismo contenedor oracle-xe que ya usan
SQL Developer y los scripts de sql/. Un pool de conexiones se crea una sola
vez al arrancar la app y cada request pide/devuelve una conexión del pool.
"""

import os
import oracledb

_pool = None


def get_pool():
    global _pool
    if _pool is None:
        _pool = oracledb.create_pool(
            user=os.environ.get("DB_USER", "turismo_uq"),
            password=os.environ.get("DB_PASSWORD", "TurismoUQ_2026"),
            dsn=os.environ.get("DB_DSN", "localhost:1521/XEPDB1"),
            min=1,
            max=5,
            increment=1,
        )
    return _pool


def get_connection():
    """Devuelve una conexión tomada del pool. Llamar connection.close() la
    regresa al pool (python-oracledb no la cierra de verdad)."""
    return get_pool().acquire()


def fetch_all(sql, binds=None):
    """Ejecuta un SELECT y devuelve (columnas, filas) como listas simples,
    listas para pintar en una tabla HTML."""
    binds = binds or {}
    conn = get_connection()
    try:
        cur = conn.cursor()
        cur.execute(sql, binds)
        columns = [d[0] for d in cur.description]
        rows = cur.fetchall()
        return columns, rows
    finally:
        conn.close()
