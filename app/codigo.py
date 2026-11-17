"""
TurismoUQ · Código fuente para mostrar en pantalla junto a cada función.

Dos orígenes, y la pantalla dice cuál es:
   · procedimientos y funciones: se leen de USER_SOURCE, o sea, el código
     que está compilado en Oracle en este momento (no una copia);
   · consultas, índices, vistas y perfil: se toman literalmente de los
     scripts de sql/, los mismos que se entregan en el repositorio.
"""

import os
import re

import db

CARPETA_SQL = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sql")

SQL_FUENTE = """
SELECT text FROM user_source
 WHERE name = :paquete AND type = 'PACKAGE BODY'
 ORDER BY line"""


def procedimiento(paquete, nombre):
    """Texto de PROCEDURE/FUNCTION `nombre` dentro del cuerpo del paquete,
    desde su declaración hasta su END."""
    _, filas = db.fetch_all(SQL_FUENTE, {"paquete": paquete.upper()})
    lineas = [f[0].rstrip("\n") for f in filas]
    inicio = re.compile(rf"^\s*(PROCEDURE|FUNCTION)\s+{nombre}\b", re.I)
    fin = re.compile(rf"^\s*END\s+{nombre}\s*;", re.I)
    dentro, salida = False, []
    for linea in lineas:
        if not dentro and inicio.search(linea):
            dentro = True
        if dentro:
            salida.append(linea)
            if fin.search(linea):
                break
    texto = "\n".join(salida) if salida else f"-- {paquete}.{nombre} no está compilado en la base"
    return {"titulo": f"{paquete.lower()}.{nombre.lower()}",
            "origen": "En la base de datos (USER_SOURCE)",
            "texto": _quitar_sangria(texto)}


def fragmento(archivo, desde, hasta, titulo=None):
    """Líneas de sql/`archivo` desde la primera que contiene `desde` hasta la
    primera (posterior) que contiene `hasta`, ambas incluidas."""
    with open(os.path.join(CARPETA_SQL, archivo), encoding="utf-8") as f:
        lineas = f.read().splitlines()
    salida, dentro = [], False
    for linea in lineas:
        if not dentro and desde in linea:
            dentro = True
        if dentro:
            salida.append(linea)
            if hasta in linea and len(salida) > 1:
                break
    return {"titulo": titulo or archivo, "origen": f"sql/{archivo}",
            "texto": "\n".join(salida)}


def consultas_del_script(archivo):
    """Separa un script de consultas en (comentario explicativo, sentencia).
    Cada consulta es el bloque de comentarios '-- ====' + PROMPT + sentencia
    terminada en ';'. Devuelve una lista en el orden del archivo."""
    with open(os.path.join(CARPETA_SQL, archivo), encoding="utf-8") as f:
        texto = f.read()
    bloques = re.split(r"\n(?=-- =+\n-- CONSULTA)", texto)
    resultado = []
    for bloque in bloques[1:]:
        lineas = bloque.splitlines()
        comentario = [l for l in lineas if l.startswith("--")]
        titulo = next((l[3:].strip() for l in comentario if "CONSULTA" in l), "")
        titulo = " · ".join(p.strip().capitalize() for p in titulo.split("·"))
        cuerpo = [l for l in lineas if not l.startswith("--") and not l.startswith("PROMPT")]
        sentencia = "\n".join(cuerpo).strip()
        sentencia = sentencia[: sentencia.rfind(";")] if ";" in sentencia else sentencia
        explicacion = "\n".join(l[3:] if len(l) > 3 else "" for l in comentario
                                if not set(l[3:].strip()) <= {"="} and "CONSULTA" not in l)
        resultado.append({"titulo": titulo, "explicacion": explicacion.strip(),
                          "sql": sentencia.strip(), "origen": f"sql/{archivo}"})
    return resultado


def _quitar_sangria(texto):
    lineas = texto.splitlines()
    sangrias = [len(l) - len(l.lstrip()) for l in lineas if l.strip()]
    quitar = min(sangrias) if sangrias else 0
    return "\n".join(l[quitar:] for l in lineas)
