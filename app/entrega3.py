"""
TurismoUQ · Pantallas de la Entrega 3 (transacciones, concurrencia,
índices y seguridad).

Igual que el resto de la interfaz, aquí no vive lógica de negocio: cada
pantalla llama a lo que crearon los scripts sql/13 a sql/19
(PKG_TRANSACCIONES, PKG_MEDICION, las vistas de recepción y los usuarios de
demostración) y muestra lo que la base de datos responde.

Todas las reservas que crean estas pantallas llevan 'DEMO_E3 web' en
OBSERVACIONES y se pueden borrar con el botón "Limpiar" de Transacciones;
el experimento de concurrencia borra las suyas al terminar.
"""

import re
import threading
import time
from datetime import timedelta

import oracledb
from flask import Blueprint, flash, redirect, render_template, request, url_for

import db

bp = Blueprint("e3", __name__, url_prefix="/entrega3")


@bp.app_template_filter("celda")
def celda(valor):
    """Valor de una celda para mostrar: fechas sin la hora 00:00:00 que
    agrega Oracle a un DATE, y vacío en lugar de None."""
    if valor is None:
        return ""
    if hasattr(valor, "hour") and (valor.hour, valor.minute, valor.second) == (0, 0, 0):
        return valor.strftime("%Y-%m-%d")
    return valor

MARCA_DEMO = "DEMO_E3 web"
PASSWORD_DEMO = "Demo_UQ2026"   # la que crea sql/18_seguridad.sql


def _codigo_ora(exc):
    """ORA-NNNNN de una excepción de python-oracledb, como número negativo
    (igual que SQLCODE en PL/SQL)."""
    err = exc.args[0]
    return -getattr(err, "code", 0)


def _mensaje_ora(exc):
    return str(exc.args[0].message).split("\n")[0].strip()


# =====================================================================
# 1. TRANSACCIONES · pkg_transacciones.sp_reservar_y_pagar
# =====================================================================
# Cada escenario es un caso del script 15: la pantalla busca un hueco libre
# con sp_buscar_hueco y llama al procedimiento con un pago válido o inválido.
ESCENARIOS_TX = {
    "feliz": {
        "titulo": "Pago correcto",
        "detalle": "Paga exactamente el valor de la estadía.",
        "esperado": "Reserva CONFIRMADA y 1 pago: se confirmaron las dos cosas juntas.",
    },
    "monto": {
        "titulo": "Pago mayor al total (-20011)",
        "detalle": "Intenta pagar 999.999.999: lo rechaza el procedimiento.",
        "esperado": "ROLLBACK TO sp_antes_pago: la reserva queda PENDIENTE con 0 pagos (rollback parcial).",
    },
    "medio": {
        "titulo": "Medio de pago inválido (CHECK)",
        "detalle": "Paga con 'BITCOIN': lo rechaza el CHECK ck_pago_medio de la Entrega 1.",
        "esperado": "Mismo rollback parcial, esta vez provocado por una restricción del modelo.",
    },
    "capacidad": {
        "titulo": "Reserva inválida (-20003)",
        "detalle": "Pide 5 huéspedes más de los que caben en la habitación.",
        "esperado": "ROLLBACK TO sp_inicio: no queda NADA grabado (rollback total) y el error sube.",
    },
}

PLSQL_RESERVAR_Y_PAGAR = """
DECLARE
   v_habs  pkg_transacciones.t_lista_habitaciones;
   v_res   VARCHAR2(20);
BEGIN
   v_habs(1) := :hab;
   pkg_transacciones.sp_reservar_y_pagar(
      p_id_cliente     => :cli,
      p_id_alojamiento => :aloj,
      p_fecha_checkin  => :fin,
      p_fecha_checkout => :fout,
      p_num_huespedes  => :huespedes,
      p_habitaciones   => v_habs,
      p_valor_pago     => :valor,
      p_medio_pago     => :medio,
      p_id_reserva     => :id_reserva,
      p_resultado      => v_res,
      p_observaciones  => :obs);
   :resultado := v_res;
END;"""

PLSQL_BUSCAR_HUECO = """
BEGIN
   pkg_transacciones.sp_buscar_hueco(:noches, :hab, :aloj, :fecha);
END;"""

# El mismo bloque 4 de sql/15_pruebas_transacciones.sql: los conteos que ve
# la propia transacción después de cada paso. Termina con ROLLBACK.
PLSQL_ANATOMIA = """
DECLARE
   v_habs    pkg_turismo.t_lista_habitaciones;
   v_id_aloj NUMBER;
   v_fecha   DATE;
   v_id_cli  NUMBER;
   v_id_res  NUMBER;
   v_res     PLS_INTEGER;
   v_lin     PLS_INTEGER;
   v_pag     PLS_INTEGER;

   PROCEDURE foto(p_paso VARCHAR2) IS
   BEGIN
      SELECT COUNT(*) INTO v_res FROM reserva            WHERE id_reserva = v_id_res;
      SELECT COUNT(*) INTO v_lin FROM reserva_habitacion WHERE id_reserva = v_id_res;
      SELECT COUNT(*) INTO v_pag FROM pago               WHERE id_reserva = v_id_res;
      DBMS_OUTPUT.PUT_LINE(p_paso || '|' || v_res || '|' || v_lin || '|' || v_pag);
   END;
BEGIN
   pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_id_aloj, v_fecha);
   SELECT MIN(id_cliente) INTO v_id_cli FROM cliente;

   SAVEPOINT demo_inicio;
   pkg_turismo.sp_crear_reserva(v_id_cli, v_id_aloj, v_fecha, v_fecha + 2, 1, v_habs, v_id_res);
   foto('SAVEPOINT demo_inicio  ->  sp_crear_reserva');

   SAVEPOINT demo_antes_pago;
   INSERT INTO pago (id_reserva, fecha_pago, valor, medio_pago, estado, referencia)
   VALUES (v_id_res, SYSDATE, 50000, 'EFECTIVO', 'APROBADO', 'DEMO-WEB-' || v_id_res || '-A');
   foto('SAVEPOINT demo_antes_pago  ->  INSERT primer pago');

   INSERT INTO pago (id_reserva, fecha_pago, valor, medio_pago, estado, referencia)
   VALUES (v_id_res, SYSDATE, 20000, 'EFECTIVO', 'APROBADO', 'DEMO-WEB-' || v_id_res || '-B');
   foto('INSERT segundo pago');

   ROLLBACK TO SAVEPOINT demo_antes_pago;
   foto('ROLLBACK TO demo_antes_pago');

   ROLLBACK TO SAVEPOINT demo_inicio;
   foto('ROLLBACK TO demo_inicio');

   ROLLBACK;
END;"""

SQL_ESTADO_RESERVA = """
SELECT r.id_reserva, r.estado, r.fecha_checkin, r.fecha_checkout, r.valor_total,
       (SELECT COUNT(*) FROM reserva_habitacion rh WHERE rh.id_reserva = r.id_reserva) AS lineas,
       (SELECT COUNT(*) FROM pago p WHERE p.id_reserva = r.id_reserva) AS pagos,
       (SELECT NVL(SUM(p.valor), 0) FROM pago p WHERE p.id_reserva = r.id_reserva) AS pagado,
       r.observaciones
  FROM reserva r
 WHERE r.id_reserva = :id"""

SQL_DEMOS_WEB = """
SELECT r.id_reserva, r.estado, r.fecha_checkin, r.fecha_checkout, r.valor_total,
       (SELECT COUNT(*) FROM pago p WHERE p.id_reserva = r.id_reserva) AS pagos,
       r.observaciones
  FROM reserva r
 WHERE r.observaciones LIKE :marca || '%'
 ORDER BY r.id_reserva DESC"""


@bp.route("/transacciones", methods=["GET", "POST"])
def transacciones():
    resultado = None
    anatomia = None

    if request.method == "POST":
        escenario = request.form.get("escenario")
        conn = db.connect_standalone()
        try:
            cur = conn.cursor()
            if escenario == "anatomia":
                db.enable_output(cur)
                cur.execute(PLSQL_ANATOMIA)
                anatomia = [linea.split("|") for linea in db.read_output(cur)]
            elif escenario in ESCENARIOS_TX:
                resultado = _correr_escenario(conn, escenario)
        finally:
            conn.close()

    _, demos = db.fetch_all(SQL_DEMOS_WEB, {"marca": MARCA_DEMO})
    return render_template(
        "e3_transacciones.html",
        escenarios=ESCENARIOS_TX,
        resultado=resultado,
        anatomia=anatomia,
        demos=demos,
    )


def _correr_escenario(conn, escenario):
    cur = conn.cursor()
    hab, aloj, fecha = cur.var(int), cur.var(int), cur.var(oracledb.DATETIME)
    cur.execute(PLSQL_BUSCAR_HUECO, {"noches": 2, "hab": hab, "aloj": aloj, "fecha": fecha})
    hab, aloj, fecha_in = hab.getvalue(), aloj.getvalue(), fecha.getvalue()
    fecha_out = fecha_in + timedelta(days=2)

    cli = cur.execute("SELECT MIN(id_cliente) FROM cliente").fetchone()[0]
    capacidad = cur.execute(
        "SELECT capacidad FROM habitacion WHERE id_habitacion = :h", {"h": hab}
    ).fetchone()[0]
    valor_estadia = cur.callfunc(
        "pkg_turismo.fn_valor_estadia", oracledb.NUMBER, [hab, fecha_in, fecha_out]
    )
    antes = cur.execute("SELECT COUNT(*) FROM reserva").fetchone()[0]

    valor, medio, huespedes = valor_estadia, "TARJETA_CREDITO", 1
    if escenario == "monto":
        valor = 999999999
    elif escenario == "medio":
        valor, medio = 10000, "BITCOIN"
    elif escenario == "capacidad":
        huespedes = capacidad + 5

    id_var, res_var = cur.var(oracledb.NUMBER), cur.var(str)
    llamada = {
        "habitacion": hab, "alojamiento": aloj,
        "checkin": fecha_in.date(), "checkout": fecha_out.date(),
        "huespedes": huespedes, "valor_pago": valor, "medio_pago": medio,
        "valor_estadia": valor_estadia,
    }
    salida = {"escenario": escenario, "llamada": llamada, "error": None,
              "fila": None, "columnas": None, "antes": antes}
    try:
        cur.execute(PLSQL_RESERVAR_Y_PAGAR, {
            "hab": hab, "cli": cli, "aloj": aloj, "fin": fecha_in, "fout": fecha_out,
            "huespedes": huespedes, "valor": valor, "medio": medio,
            "id_reserva": id_var, "resultado": res_var,
            "obs": f"{MARCA_DEMO} · {ESCENARIOS_TX[escenario]['titulo']}",
        })
        salida["p_resultado"] = res_var.getvalue()
        cur.execute(SQL_ESTADO_RESERVA, {"id": int(id_var.getvalue())})
        salida["columnas"] = [d[0] for d in cur.description]
        salida["fila"] = cur.fetchone()
    except oracledb.DatabaseError as exc:
        salida["error"] = _mensaje_ora(exc)
        conn.rollback()
    salida["despues"] = cur.execute("SELECT COUNT(*) FROM reserva").fetchone()[0]
    return salida


@bp.route("/transacciones/limpiar", methods=["POST"])
def transacciones_limpiar():
    conn = db.connect_standalone()
    try:
        cur = conn.cursor()
        cur.execute("DELETE FROM reserva WHERE observaciones LIKE :m || '%'", {"m": MARCA_DEMO})
        n = cur.rowcount
        conn.commit()
        flash(f"Se borraron {n} reservas de demostración (con sus líneas y pagos).", "success")
    finally:
        conn.close()
    return redirect(url_for("e3.transacciones"))


# =====================================================================
# 2. CONCURRENCIA · dos sesiones reales por la misma habitación
# =====================================================================
# Lo mismo que sql/16_concurrencia.sql, pero las dos sesiones son dos
# conexiones de Python: A en el hilo principal, B en un hilo aparte. Una
# tercera conexión mira V$SESSION mientras A retiene la habitación.
MODOS_CONCURRENCIA = {
    "sin_bloqueo": {
        "titulo": "ANTES · sin bloqueo",
        "llamada": "pkg_turismo.sp_crear_reserva",
        "espera": None,
    },
    "for_update": {
        "titulo": "DESPUÉS · con SELECT ... FOR UPDATE",
        "llamada": "pkg_transacciones.sp_crear_reserva_segura",
        "espera": None,
    },
    "nowait": {
        "titulo": "Variante · FOR UPDATE NOWAIT",
        "llamada": "pkg_transacciones.sp_crear_reserva_segura",
        "espera": 0,
    },
}

PLSQL_RESERVA_CONC = """
DECLARE
   v_habs pkg_turismo.t_lista_habitaciones;
   v_id   NUMBER;
BEGIN
   v_habs(1) := :hab;
   {llamada}(:cli, :aloj, :fin, :fout, 1, v_habs, v_id{espera});
   UPDATE reserva SET observaciones = :obs WHERE id_reserva = v_id;
   :id_reserva := v_id;
END;"""

SQL_BLOQUEADAS = """
SELECT s.sid, s.blocking_session, s.event, s.seconds_in_wait, o.object_name
  FROM v$session s
  LEFT JOIN user_objects o ON o.object_id = s.row_wait_obj#
 WHERE s.blocking_session = :sid_a"""

SQL_RESERVAS_HAB = """
SELECT r.id_reserva, rh.id_habitacion, r.fecha_checkin, r.fecha_checkout, r.estado, r.observaciones
  FROM reserva r
  JOIN reserva_habitacion rh ON rh.id_reserva = r.id_reserva
 WHERE rh.id_habitacion = :hab
   AND r.estado <> 'CANCELADA'
   AND r.fecha_checkin < :fout AND :fin < r.fecha_checkout
 ORDER BY r.id_reserva"""

RETENCION_A = 4.0   # segundos que A mantiene su transacción abierta


@bp.route("/concurrencia", methods=["GET", "POST"])
def concurrencia():
    resultado = None
    if request.method == "POST":
        modo = request.form.get("modo")
        if modo in MODOS_CONCURRENCIA:
            resultado = _experimento(modo)
    return render_template("e3_concurrencia.html", modos=MODOS_CONCURRENCIA,
                           resultado=resultado, retencion=RETENCION_A)


def _experimento(modo):
    cfg = MODOS_CONCURRENCIA[modo]
    marca = f"{MARCA_DEMO} conc"
    t0 = time.perf_counter()
    eventos = []
    candado = threading.Lock()

    def evento(quien, texto, tipo="secondary"):
        with candado:
            eventos.append({"t": time.perf_counter() - t0, "quien": quien, "texto": texto, "tipo": tipo})

    conn_a = db.connect_standalone()
    conn_b = db.connect_standalone()
    conn_m = db.connect_standalone()
    try:
        cur_a = conn_a.cursor()
        cur_a.execute("DELETE FROM reserva WHERE observaciones LIKE :m || '%'", {"m": marca})
        conn_a.commit()

        hab, aloj, fecha = cur_a.var(int), cur_a.var(int), cur_a.var(oracledb.DATETIME)
        cur_a.execute(PLSQL_BUSCAR_HUECO, {"noches": 2, "hab": hab, "aloj": aloj, "fecha": fecha})
        hab, aloj, fin = hab.getvalue(), aloj.getvalue(), fecha.getvalue()
        fout = fin + timedelta(days=2)
        cli_a, cli_b = cur_a.execute("SELECT MIN(id_cliente), MAX(id_cliente) FROM cliente").fetchone()
        sid_a = cur_a.execute("SELECT SYS_CONTEXT('USERENV','SID') FROM dual").fetchone()[0]
        sid_b = conn_b.cursor().execute("SELECT SYS_CONTEXT('USERENV','SID') FROM dual").fetchone()[0]

        plsql_a = PLSQL_RESERVA_CONC.format(llamada=cfg["llamada"], espera="")
        espera_b = "" if cfg["espera"] is None else f", p_espera_seg => {cfg['espera']}"
        plsql_b = PLSQL_RESERVA_CONC.format(llamada=cfg["llamada"], espera=espera_b)
        binds = {"hab": hab, "aloj": aloj, "fin": fin, "fout": fout}

        # --- Sesión A: reserva y NO confirma ---
        id_a = cur_a.var(oracledb.NUMBER)
        cur_a.execute(plsql_a, {**binds, "cli": cli_a, "obs": f"{marca} sesion A", "id_reserva": id_a})
        evento("A", f"Reserva {int(id_a.getvalue())} creada con {cfg['llamada']} · SIN COMMIT "
                    f"(A retiene la transacción {RETENCION_A:.0f} s)", "primary")

        # --- Sesión B: en otro hilo, la misma habitación y fechas ---
        res_b = {}

        def sesion_b():
            cur_b = conn_b.cursor()
            id_b = cur_b.var(oracledb.NUMBER)
            inicio = time.perf_counter()
            evento("B", f"Intenta reservar la misma habitación {hab}")
            try:
                cur_b.execute(plsql_b, {**binds, "cli": cli_b, "obs": f"{marca} sesion B", "id_reserva": id_b})
                conn_b.commit()
                res_b["ok"] = True
                evento("B", f"COMMIT: reserva {int(id_b.getvalue())} creada "
                            f"(esperó {time.perf_counter() - inicio:.2f} s)", "danger")
            except oracledb.DatabaseError as exc:
                conn_b.rollback()
                res_b["ok"] = False
                evento("B", f"RECHAZADA tras esperar {time.perf_counter() - inicio:.2f} s: "
                            f"{_mensaje_ora(exc)}", "success")
            res_b["espera"] = time.perf_counter() - inicio

        hilo = threading.Thread(target=sesion_b)
        time.sleep(0.3)
        hilo.start()

        # --- Monitor: qué ve V$SESSION mientras A retiene ---
        time.sleep(RETENCION_A / 2)
        bloqueadas = conn_m.cursor().execute(SQL_BLOQUEADAS, {"sid_a": sid_a}).fetchall()
        if bloqueadas:
            for sid, bloq, ev, seg, obj in bloqueadas:
                evento("Monitor", f"V$SESSION: la sesión {sid} (B) está BLOQUEADA por la sesión {bloq} (A) · "
                                  f"evento «{ev}» · espera una fila de {obj} desde hace {seg} s", "warning")
        else:
            evento("Monitor", "V$SESSION: ninguna sesión está esperando a A", "light")
        time.sleep(RETENCION_A / 2)

        # El evento se anota ANTES de llamar a commit(): en cuanto Oracle
        # confirma, B continúa y su evento podría quedar registrado primero.
        evento("A", "COMMIT (libera cualquier bloqueo que tuviera)", "primary")
        conn_a.commit()
        hilo.join(timeout=30)

        filas = conn_m.cursor().execute(SQL_RESERVAS_HAB, {"hab": hab, "fin": fin, "fout": fout}).fetchall()
        demo = [f for f in filas if (f[5] or "").startswith(marca)]

        cur_a.execute("DELETE FROM reserva WHERE observaciones LIKE :m || '%'", {"m": marca})
        conn_a.commit()

        eventos.sort(key=lambda e: e["t"])
        return {
            "modo": modo, "titulo": cfg["titulo"], "hab": hab, "fin": fin.date(), "fout": fout.date(),
            "sid_a": sid_a, "sid_b": sid_b, "eventos": eventos, "reservas": demo,
            "bloqueo_visto": bool(bloqueadas), "espera_b": res_b.get("espera"),
            "b_ok": res_b.get("ok"),
        }
    finally:
        for c in (conn_a, conn_b, conn_m):
            try:
                c.close()
            except oracledb.Error:
                pass


# =====================================================================
# 3. ÍNDICES · plan y lecturas lógicas antes / después
# =====================================================================
# "Antes" se reproduce SIN borrar el índice que dejó sql/17_indices.sql:
# la pista NO_INDEX le prohíbe al optimizador usarlo, que para el plan es
# lo mismo que no tenerlo. Los índices de Q4 y Q5 (los que NO ayudan) se
# borraron en el script 17, así que aquí se crean, se miden y se borran.
CONSULTAS_INDICES = {
    "q1": {
        "titulo": "Q1 · Agenda de llegadas de un alojamiento",
        "tipo": "Índice compuesto",
        "indice": "ix_reserva_aloj_checkin (id_alojamiento, fecha_checkin)",
        "sql": ("SELECT {hint} r.id_reserva, r.fecha_checkin, r.fecha_checkout, r.num_huespedes, r.estado, "
                "c.nombres || ' ' || c.apellidos AS cliente "
                "FROM reserva r JOIN cliente c ON c.id_cliente = r.id_cliente "
                "WHERE r.id_alojamiento = 10 "
                "AND r.fecha_checkin >= DATE '2025-12-01' AND r.fecha_checkin < DATE '2026-01-01' "
                "ORDER BY r.fecha_checkin"),
        "antes": "/*+ NO_INDEX(r ix_reserva_aloj_checkin) */",
        "explicacion": "Igualdad (alojamiento) primero y rango (fecha) después: las entradas útiles "
                       "quedan contiguas en el índice y además salen ya ordenadas por fecha.",
    },
    "q2": {
        "titulo": "Q2 · Buscar cliente por correo sin distinguir mayúsculas",
        "tipo": "Índice basado en función",
        "indice": "ix_cliente_email_upper (UPPER(email))",
        "sql": ("SELECT {hint} c.id_cliente, c.numero_documento, c.nombres, c.apellidos, c.email "
                "FROM cliente c WHERE UPPER(c.email) = UPPER('Cliente1500@Correo-Demo.Co')"),
        "antes": "/*+ NO_INDEX(c ix_cliente_email_upper) */",
        "explicacion": "CLIENTE ya tenía índice UNIQUE sobre email, pero UPPER(email) lo inutiliza. "
                       "El índice sobre la misma expresión convierte el filtro en acceso directo.",
    },
    "q3": {
        "titulo": "Q3 · Historial de reservas de un cliente",
        "tipo": "Índice sobre FK",
        "indice": "ix_reserva_cliente (id_cliente)",
        "sql": ("SELECT {hint} r.id_reserva, a.nombre AS alojamiento, r.fecha_checkin, r.estado, r.valor_total "
                "FROM reserva r JOIN alojamiento a ON a.id_alojamiento = r.id_alojamiento "
                "WHERE r.id_cliente = 1500 ORDER BY r.fecha_checkin DESC"),
        "antes": "/*+ NO_INDEX(r ix_reserva_cliente) */",
        "explicacion": "~8 filas de 25.000: la más selectiva. Además evita que borrar un cliente "
                       "bloquee la tabla RESERVA entera.",
    },
    "q4": {
        "titulo": "Q4 · Reservas COMPLETADAS por alojamiento",
        "tipo": "Caso donde el índice NO ayuda",
        "indice": "ix_reserva_estado (estado) · se crea y se borra en esta prueba",
        "crear": "CREATE INDEX ix_reserva_estado ON reserva (estado) TABLESPACE ts_turismo_idx",
        "borrar": "DROP INDEX ix_reserva_estado",
        "sql": ("SELECT {hint} r.id_alojamiento, COUNT(*) AS reservas, SUM(r.valor_total) AS valor "
                "FROM reserva r WHERE r.estado = 'COMPLETADA' GROUP BY r.id_alojamiento"),
        "antes": "/*+ FULL(r) */",
        "forzado": "/*+ INDEX(r ix_reserva_estado) */",
        "explicacion": "COMPLETADA es el ~80 % de las filas. El optimizador ignora el índice; "
                       "si se le obliga a usarlo, lee más bloques y tarda más que el barrido completo.",
    },
    "q5": {
        "titulo": "Q5 · Llegadas de un mes con TRUNC(fecha_checkin,'MM')",
        "tipo": "Caso límite (clustering factor)",
        "indice": "ix_reserva_mes_checkin (TRUNC(fecha_checkin,'MM')) · se crea y se borra",
        "crear": "CREATE INDEX ix_reserva_mes_checkin ON reserva (TRUNC(fecha_checkin, 'MM')) TABLESPACE ts_turismo_idx",
        "borrar": "DROP INDEX ix_reserva_mes_checkin",
        "sql": ("SELECT {hint} r.canal, COUNT(*) AS reservas, SUM(r.valor_total) AS valor "
                "FROM reserva r WHERE TRUNC(r.fecha_checkin, 'MM') = DATE '2025-12-01' "
                "GROUP BY r.canal ORDER BY valor DESC"),
        "antes": "/*+ FULL(r) */",
        "forzado": "/*+ INDEX(r ix_reserva_mes_checkin) */",
        "explicacion": "Las llegadas de un mes están dispersas en casi todos los bloques: el índice "
                       "casi no ahorra lecturas y el optimizador lo descarta.",
    },
}

RE_MEDIDA = re.compile(r"lecturas lógicas/ejec =\s*([\d.]+).*ms/ejec =\s*([\d.]+).*filas = ([\d.]+)")


def _plan_y_medida(cur, sql, etiqueta, reps=50):
    db.enable_output(cur)
    cur.callproc("pkg_medicion.plan", [sql])
    plan = db.read_output(cur)
    cur.callproc("pkg_medicion.medir", [etiqueta, sql, reps])
    linea = " ".join(db.read_output(cur))
    m = RE_MEDIDA.search(linea)
    gets, ms, filas = (float(m.group(1)), float(m.group(2)), float(m.group(3))) if m else (None, None, None)
    return {"etiqueta": etiqueta, "sql": sql, "plan": "\n".join(plan),
            "gets": gets, "ms": ms, "filas": filas}


@bp.route("/indices", methods=["GET", "POST"])
def indices():
    resultado = None
    libre = None
    sql_libre = ""
    if request.method == "POST":
        conn = db.connect_standalone()
        try:
            cur = conn.cursor()
            clave = request.form.get("consulta")
            if clave in CONSULTAS_INDICES:
                resultado = _medir_consulta(cur, clave)
            elif clave == "libre":
                sql_libre = (request.form.get("sql_libre") or "").strip().rstrip(";")
                if not re.match(r"^\s*(select|with)\b", sql_libre, re.I):
                    flash("Solo se permiten consultas SELECT (o WITH ... SELECT).", "danger")
                else:
                    try:
                        libre = _plan_y_medida(cur, sql_libre, "Consulta libre", reps=20)
                    except oracledb.DatabaseError as exc:
                        flash(f"La consulta falló: {_mensaje_ora(exc)}", "danger")
        finally:
            conn.close()
    return render_template("e3_indices.html", consultas=CONSULTAS_INDICES,
                           resultado=resultado, libre=libre, sql_libre=sql_libre)


def _medir_consulta(cur, clave):
    cfg = CONSULTAS_INDICES[clave]
    medidas = []
    creado = False
    try:
        if "crear" in cfg:
            try:
                cur.execute(cfg["borrar"])
            except oracledb.DatabaseError:
                pass
            cur.execute(cfg["crear"])
            creado = True
            cur.callproc("dbms_stats.gather_table_stats",
                         keyword_parameters={"ownname": "TURISMO_UQ", "tabname": "RESERVA",
                                             "method_opt": "FOR ALL HIDDEN COLUMNS SIZE AUTO",
                                             "cascade": True})
        medidas.append(_plan_y_medida(cur, cfg["sql"].format(hint=cfg["antes"]),
                                      "Antes (sin índice)"))
        medidas.append(_plan_y_medida(cur, cfg["sql"].format(hint=""),
                                      "Después (el optimizador decide)"))
        if "forzado" in cfg:
            medidas.append(_plan_y_medida(cur, cfg["sql"].format(hint=cfg["forzado"]),
                                          "Índice FORZADO con /*+ INDEX */"))
    finally:
        if creado:
            cur.execute(cfg["borrar"])
    base = medidas[0]["gets"] or 1
    for m in medidas:
        m["cambio"] = None if m["gets"] is None else round(100 * (m["gets"] - base) / base)
    return {"clave": clave, "cfg": cfg, "medidas": medidas}


# =====================================================================
# 4. SEGURIDAD · conectarse como cada usuario de demostración
# =====================================================================
# Cada prueba: (descripción, sentencia, resultado esperado). "OK" = debe
# funcionar; un número negativo = el ORA-xxxxx con el que Oracle debe
# rechazarla. Es la misma batería de sql/19_pruebas_seguridad.sql.
RESERVAR_AJENO = """
DECLARE
   v_habs turismo_uq.pkg_transacciones.t_lista_habitaciones;
   v_aloj NUMBER; v_fecha DATE; v_id NUMBER; v_res VARCHAR2(20); v_cli NUMBER;
BEGIN
   SELECT MIN(id_cliente) INTO v_cli FROM turismo_uq.v_recepcion_reservas;
   turismo_uq.pkg_transacciones.sp_buscar_hueco(2, v_habs(1), v_aloj, v_fecha, p_solo_aloj => 2);
   turismo_uq.pkg_transacciones.sp_reservar_y_pagar(
      v_cli, 2, v_fecha, v_fecha + 2, 1, v_habs, 10000, 'EFECTIVO', v_id, v_res, p_commit => FALSE);
END;"""

RESERVAR_PROPIO = RESERVAR_AJENO.replace("p_solo_aloj => 2", "p_solo_aloj => 1").replace(
    "v_cli, 2, v_fecha", "v_cli, 1, v_fecha")

USUARIOS_DEMO = {
    "recep1": {
        "rol": "rol_recepcion", "alcance": "Alojamiento 1",
        "vista_previa": "SELECT id_reserva, id_alojamiento, cliente, fecha_checkin, fecha_checkout, estado, "
                        "habitaciones, saldo_pendiente FROM turismo_uq.v_recepcion_reservas "
                        "ORDER BY fecha_checkin DESC FETCH FIRST 8 ROWS ONLY",
        "pruebas": [
            ("Leer su vista de reservas", "SELECT COUNT(*), MIN(id_alojamiento), MAX(id_alojamiento) FROM turismo_uq.v_recepcion_reservas", "OK"),
            ("Leer su vista de habitaciones", "SELECT COUNT(*) FROM turismo_uq.v_recepcion_habitaciones", "OK"),
            ("Reservar y cobrar en SU alojamiento (por el paquete)", RESERVAR_PROPIO, "OK"),
            ("Reservar en un alojamiento AJENO", RESERVAR_AJENO, -20020),
            ("SELECT directo a la tabla RESERVA", "SELECT COUNT(*) FROM turismo_uq.reserva", -942),
            ("SELECT directo a la tabla CLIENTE", "SELECT COUNT(*) FROM turismo_uq.cliente", -942),
            ("SELECT directo a la tabla PAGO", "SELECT COUNT(*) FROM turismo_uq.pago", -942),
            ("Modificar la vista de reservas", "UPDATE turismo_uq.v_recepcion_reservas SET num_huespedes = 1 WHERE ROWNUM = 1", -1031),
            ("Ver tarifas del administrador", "SELECT COUNT(*) FROM turismo_uq.v_admin_tarifas", -942),
            ("Crear una tabla propia", "CREATE TABLE prueba_recep (x NUMBER)", -1031),
        ],
    },
    "recep2": {
        "rol": "rol_recepcion", "alcance": "Alojamiento 2",
        "vista_previa": "SELECT id_reserva, id_alojamiento, cliente, fecha_checkin, fecha_checkout, estado, "
                        "habitaciones, saldo_pendiente FROM turismo_uq.v_recepcion_reservas "
                        "ORDER BY fecha_checkin DESC FETCH FIRST 8 ROWS ONLY",
        "pruebas": [
            ("Leer su vista de reservas (misma vista que RECEP1, otras filas)", "SELECT COUNT(*), MIN(id_alojamiento), MAX(id_alojamiento) FROM turismo_uq.v_recepcion_reservas", "OK"),
            ("SELECT directo a la tabla RESERVA", "SELECT COUNT(*) FROM turismo_uq.reserva", -942),
        ],
    },
    "admin1": {
        "rol": "rol_admin_alojamiento", "alcance": "Alojamiento 1",
        "vista_previa": "SELECT id_tarifa, id_alojamiento, categoria, id_temporada, valor_noche "
                        "FROM turismo_uq.v_admin_tarifas ORDER BY id_tarifa FETCH FIRST 8 ROWS ONLY",
        "pruebas": [
            ("Leer reservas (heredado de recepción)", "SELECT COUNT(*) FROM turismo_uq.v_recepcion_reservas", "OK"),
            ("Leer las tarifas de su alojamiento", "SELECT COUNT(*), MIN(id_alojamiento), MAX(id_alojamiento) FROM turismo_uq.v_admin_tarifas", "OK"),
            ("Cambiar un precio por la vista (luego ROLLBACK)", "UPDATE turismo_uq.v_admin_tarifas SET valor_noche = valor_noche WHERE ROWNUM = 1", "OK"),
            ("Mover una tarifa a otro alojamiento", "UPDATE turismo_uq.v_admin_tarifas SET id_alojamiento = 2 WHERE ROWNUM = 1", -1031),
            ("UPDATE directo a la tabla TARIFA", "UPDATE turismo_uq.tarifa SET valor_noche = 1 WHERE ROWNUM = 1", -942),
            ("Leer la auditoría", "SELECT COUNT(*) FROM turismo_uq.auditoria_tarifa", -942),
        ],
    },
    "gerente1": {
        "rol": "rol_gerente", "alcance": "Todo el departamento (solo lectura)",
        "vista_previa": "SELECT m.nombre AS municipio, mv.anio_mes, mv.noches_vendidas, mv.reservas, "
                        "mv.ingreso_alojamiento FROM turismo_uq.mv_ocupacion_mensual mv "
                        "JOIN turismo_uq.municipio m ON m.id_municipio = mv.id_municipio "
                        "WHERE mv.anio_mes = '2025-12' ORDER BY mv.ingreso_alojamiento DESC FETCH FIRST 8 ROWS ONLY",
        "pruebas": [
            ("Leer la tabla RESERVA completa", "SELECT COUNT(*), COUNT(DISTINCT id_alojamiento) FROM turismo_uq.reserva", "OK"),
            ("Leer la vista materializada", "SELECT COUNT(*) FROM turismo_uq.mv_ocupacion_mensual", "OK"),
            ("Modificar una tarifa", "UPDATE turismo_uq.tarifa SET valor_noche = 1 WHERE ROWNUM = 1", -1031),
            ("Borrar una reserva", "DELETE FROM turismo_uq.reserva WHERE ROWNUM = 1", -1031),
            ("Leer la auditoría", "SELECT COUNT(*) FROM turismo_uq.auditoria_tarifa", -942),
        ],
    },
    "auditor1": {
        "rol": "rol_auditor", "alcance": "Evidencia (solo lectura)",
        "vista_previa": "SELECT id_auditoria, fecha_hora, usuario_bd, operacion, id_tarifa, valor_anterior, valor_nuevo "
                        "FROM turismo_uq.auditoria_tarifa ORDER BY id_auditoria DESC FETCH FIRST 8 ROWS ONLY",
        "pruebas": [
            ("Leer la auditoría de tarifas", "SELECT COUNT(*) FROM turismo_uq.auditoria_tarifa", "OK"),
            ("Leer los pagos", "SELECT COUNT(*) FROM turismo_uq.pago", "OK"),
            ("Borrar evidencia de la auditoría", "DELETE FROM turismo_uq.auditoria_tarifa", -1031),
            ("Leer datos personales (CLIENTE)", "SELECT COUNT(*) FROM turismo_uq.cliente", -942),
            ("Ejecutar la liquidación mensual", "BEGIN turismo_uq.pkg_turismo.sp_liquidar_mes(1, 2025, 12); END;", -6550),
        ],
    },
}

SQL_MATRIZ = """
SELECT p.grantee AS rol, o.object_type AS tipo, p.table_name AS objeto,
       LISTAGG(p.privilege, ', ') WITHIN GROUP (ORDER BY p.privilege) AS privilegios
  FROM user_tab_privs_made p
  JOIN user_objects o ON o.object_name = p.table_name
                     AND o.object_type IN ('TABLE', 'VIEW', 'PACKAGE')
 WHERE p.grantee LIKE 'ROL\\_%' ESCAPE '\\'
 GROUP BY p.grantee, o.object_type, p.table_name
 ORDER BY p.grantee, o.object_type, p.table_name"""


@bp.route("/seguridad", methods=["GET", "POST"])
def seguridad():
    usuario = request.values.get("usuario")
    pruebas = vista_previa = None
    limite = None
    error_conexion = None

    if request.method == "POST" and request.form.get("accion") == "limite":
        limite = _probar_limite_sesiones()
    elif usuario in USUARIOS_DEMO:
        try:
            pruebas, vista_previa = _probar_usuario(usuario)
        except oracledb.DatabaseError as exc:
            error_conexion = _mensaje_ora(exc)

    matriz_cols, matriz = db.fetch_all(SQL_MATRIZ)
    return render_template("e3_seguridad.html", usuarios=USUARIOS_DEMO, usuario=usuario,
                           pruebas=pruebas, vista_previa=vista_previa, limite=limite,
                           error_conexion=error_conexion, matriz_cols=matriz_cols, matriz=matriz)


def _probar_usuario(usuario):
    cfg = USUARIOS_DEMO[usuario]
    conn = db.connect_standalone(usuario, PASSWORD_DEMO)
    filas = []
    try:
        cur = conn.cursor()
        quien = cur.execute("SELECT USER FROM dual").fetchone()[0]
        for descripcion, sql, esperado in cfg["pruebas"]:
            obtenido, detalle = "OK", ""
            try:
                cur.execute(sql)
                if cur.description:
                    detalle = " · ".join(str(v) for v in cur.fetchone())
                elif cur.rowcount is not None and cur.rowcount >= 0 and not sql.lstrip().upper().startswith(("DECLARE", "BEGIN")):
                    detalle = f"{cur.rowcount} fila(s) afectada(s)"
            except oracledb.DatabaseError as exc:
                obtenido, detalle = _codigo_ora(exc), _mensaje_ora(exc)
            conn.rollback()   # ninguna prueba deja cambios
            filas.append({
                "descripcion": descripcion, "sql": sql,
                "esperado": "Permitido" if esperado == "OK" else f"Rechazado (ORA{esperado:06d})",
                "obtenido": "Permitido" if obtenido == "OK" else f"Rechazado (ORA{obtenido:06d})",
                "detalle": detalle, "ok": obtenido == esperado,
            })
        cur.execute(cfg["vista_previa"])
        previa = {"columnas": [d[0] for d in cur.description], "filas": cur.fetchall()}
        return {"quien": quien, "filas": filas}, previa
    finally:
        conn.close()


def _probar_limite_sesiones():
    conexiones, intentos = [], []
    try:
        for i in range(1, 4):
            try:
                conexiones.append(db.connect_standalone("recep1", PASSWORD_DEMO))
                intentos.append((i, True, "Conectada"))
            except oracledb.DatabaseError as exc:
                intentos.append((i, False, _mensaje_ora(exc)))
    finally:
        for c in conexiones:
            c.close()
    return intentos
