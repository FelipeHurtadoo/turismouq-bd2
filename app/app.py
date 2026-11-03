"""
TurismoUQ · Interfaz administrativa (Flask)

No reemplaza ni modifica nada de los scripts sql/: es una capa delgada que
llama a PKG_TURISMO (sql/10_pkg_turismo.sql) para las operaciones de
escritura (y a PKG_TRANSACCIONES / PKG_MEDICION de la Entrega 3, en
entrega3.py), y reutiliza las vistas y consultas de la Entrega 1 para los
reportes de solo lectura. Pensada para demostrar en vivo que la lógica de
negocio vive en la base de datos, no en esta app.
"""

import os
from datetime import datetime

import oracledb
from dotenv import load_dotenv
from flask import Flask, flash, jsonify, redirect, render_template, request, url_for

import db
import entrega3
import queries as q

load_dotenv()

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", "dev-no-usar-en-produccion")

# Pantallas de la Entrega 3 (transacciones, concurrencia, índices, seguridad)
app.register_blueprint(entrega3.bp)

# Tope práctico de habitaciones por reserva en ESTE formulario. El modelo
# (RESERVA_HABITACION) no impone ningún máximo; es solo una comodidad de UI.
MAX_HABITACIONES_POR_RESERVA = 6


@app.route("/")
def index():
    return render_template("index.html")


# ---------------------------------------------------------------------
# Reservas
# ---------------------------------------------------------------------
@app.route("/reservas")
def reservas_lista():
    columns, rows = db.fetch_all(q.RESERVAS_RECIENTES)
    return render_template(
        "report.html",
        title="Reservas recientes",
        description="Las últimas 20 reservas, más recientes primero.",
        columns=columns,
        rows=rows,
        anio=None,
    )


@app.route("/reservas/nueva", methods=["GET", "POST"])
def reserva_nueva():
    _, alojamientos = db.fetch_all(q.ALOJAMIENTOS)

    if request.method == "GET":
        return render_template(
            "reserva_form.html",
            alojamientos=alojamientos,
            max_habitaciones=MAX_HABITACIONES_POR_RESERVA,
            form=None,
        )

    form = request.form
    habitaciones = request.form.getlist("habitaciones", type=int)

    if not habitaciones:
        flash("Selecciona al menos una habitación.", "danger")
        return render_template(
            "reserva_form.html",
            alojamientos=alojamientos,
            max_habitaciones=MAX_HABITACIONES_POR_RESERVA,
            form=form,
        )

    habitaciones = habitaciones[:MAX_HABITACIONES_POR_RESERVA]
    slots = habitaciones + [None] * (MAX_HABITACIONES_POR_RESERVA - len(habitaciones))

    # El tipo de PKG_TURISMO.t_lista_habitaciones es una tabla asociativa
    # PL/SQL (no un TYPE de esquema): un cliente externo como este no puede
    # enlazarla directamente. Por eso se arma dentro de un bloque anónimo,
    # que recibe solo escalares (h1..h6) y construye la colección en el
    # servidor antes de llamar al procedimiento real.
    binds = {
        "id_cliente": form.get("id_cliente", type=int),
        "id_alojamiento": form.get("id_alojamiento", type=int),
        "checkin": form.get("checkin"),
        "checkout": form.get("checkout"),
        "huespedes": form.get("huespedes", type=int),
        "canal": form.get("canal", "WEB"),
    }

    lineas_habs = []
    for i, hab_id in enumerate(slots, start=1):
        bind_name = f"h{i}"
        binds[bind_name] = hab_id
        lineas_habs.append(
            f"   IF :{bind_name} IS NOT NULL THEN "
            f"v_idx := v_idx + 1; v_habs(v_idx) := :{bind_name}; END IF;"
        )

    plsql = (
        "DECLARE\n"
        "   v_habs pkg_turismo.t_lista_habitaciones;\n"
        "   v_idx  PLS_INTEGER := 0;\n"
        "BEGIN\n"
        + "\n".join(lineas_habs)
        + "\n"
        "   pkg_turismo.sp_crear_reserva(\n"
        "      p_id_cliente     => :id_cliente,\n"
        "      p_id_alojamiento => :id_alojamiento,\n"
        "      p_fecha_checkin  => TO_DATE(:checkin, 'YYYY-MM-DD'),\n"
        "      p_fecha_checkout => TO_DATE(:checkout, 'YYYY-MM-DD'),\n"
        "      p_num_huespedes  => :huespedes,\n"
        "      p_habitaciones   => v_habs,\n"
        "      p_id_reserva     => :id_reserva,\n"
        "      p_canal          => :canal);\n"
        "   COMMIT;\n"
        "END;"
    )

    conn = db.get_connection()
    try:
        cur = conn.cursor()
        id_reserva_var = cur.var(oracledb.NUMBER)
        binds["id_reserva"] = id_reserva_var
        cur.execute(plsql, binds)
        nueva_id = int(id_reserva_var.getvalue())
        flash(f"Reserva {nueva_id} creada correctamente.", "success")
        return redirect(url_for("reservas_lista"))
    except oracledb.DatabaseError as exc:
        flash(f"No se pudo crear la reserva: {exc}", "danger")
        return render_template(
            "reserva_form.html",
            alojamientos=alojamientos,
            max_habitaciones=MAX_HABITACIONES_POR_RESERVA,
            form=form,
        )
    finally:
        conn.close()


@app.route("/api/habitaciones")
def api_habitaciones():
    id_alojamiento = request.args.get("id_alojamiento", type=int)
    if not id_alojamiento:
        return jsonify([])
    columns, rows = db.fetch_all(
        q.HABITACIONES_DE_ALOJAMIENTO, {"id_alojamiento": id_alojamiento}
    )
    return jsonify([dict(zip(columns, row)) for row in rows])


@app.route("/api/clientes/buscar")
def api_cliente_buscar():
    tipo = request.args.get("tipo_documento", "")
    numero = request.args.get("numero_documento", "")
    if not tipo or not numero:
        return jsonify(None)
    columns, rows = db.fetch_all(
        q.CLIENTE_POR_DOCUMENTO,
        {"tipo_documento": tipo, "numero_documento": numero},
    )
    if not rows:
        return jsonify(None)
    return jsonify(dict(zip([c.lower() for c in columns], rows[0])))


@app.route("/api/clientes/crear", methods=["POST"])
def api_cliente_crear():
    data = request.form
    campos_obligatorios = {
        "tipo_documento": data.get("tipo_documento"),
        "numero_documento": data.get("numero_documento"),
        "nombres": data.get("nombres"),
        "apellidos": data.get("apellidos"),
        "email": data.get("email"),
    }
    faltantes = [k for k, v in campos_obligatorios.items() if not v]
    if faltantes:
        return jsonify({"error": f"Faltan campos obligatorios: {', '.join(faltantes)}."}), 400

    binds = {
        **campos_obligatorios,
        "telefono": data.get("telefono") or None,
        "fecha_nacimiento": data.get("fecha_nacimiento") or None,
        "pais": data.get("pais") or None,
        "ciudad_origen": data.get("ciudad_origen") or None,
    }

    conn = db.get_connection()
    try:
        cur = conn.cursor()
        id_cliente_var = cur.var(oracledb.NUMBER)
        binds["id_cliente"] = id_cliente_var
        cur.execute(q.CLIENTE_INSERT, binds)
        conn.commit()
        nuevo_id = int(id_cliente_var.getvalue()[0])
        return jsonify(
            {
                "id_cliente": nuevo_id,
                "nombres": campos_obligatorios["nombres"],
                "apellidos": campos_obligatorios["apellidos"],
            }
        )
    except oracledb.DatabaseError as exc:
        conn.rollback()
        # Típicamente UQ_CLIENTE_DOC o UQ_CLIENTE_EMAIL si el documento o el
        # correo ya existían (p. ej. carrera contra otra pestaña), o
        # CK_CLIENTE_EMAIL si el correo no tiene '@'.
        return jsonify({"error": str(exc)}), 400
    finally:
        conn.close()


@app.route("/api/valor-estadia")
def api_valor_estadia():
    """Llama a pkg_turismo.fn_valor_estadia para una habitación y un rango
    de fechas, y devuelve el valor calculado. Es la función más difícil del
    proyecto (Entrega 2); esto deja verla en acción desde el formulario de
    reserva, ANTES de confirmar, no solo como cálculo interno de
    sp_crear_reserva."""
    id_habitacion = request.args.get("id_habitacion", type=int)
    checkin = request.args.get("checkin")
    checkout = request.args.get("checkout")
    if not (id_habitacion and checkin and checkout):
        return jsonify({"error": "Faltan parámetros."}), 400

    try:
        fecha_in = datetime.strptime(checkin, "%Y-%m-%d")
        fecha_out = datetime.strptime(checkout, "%Y-%m-%d")
    except ValueError:
        return jsonify({"error": "Fechas inválidas."}), 400

    conn = db.get_connection()
    try:
        cur = conn.cursor()
        valor = cur.callfunc(
            "pkg_turismo.fn_valor_estadia",
            oracledb.NUMBER,
            [id_habitacion, fecha_in, fecha_out],
        )
        return jsonify({"id_habitacion": id_habitacion, "valor": float(valor)})
    except oracledb.DatabaseError as exc:
        # p. ej. -20001 (checkout <= checkin) o -20005 (falta tarifa/calendario
        # para alguna noche de la estadía).
        return jsonify({"error": str(exc)}), 400
    finally:
        conn.close()


# ---------------------------------------------------------------------
# Liquidación mensual (cursor explícito con parámetros)
# ---------------------------------------------------------------------
@app.route("/liquidacion")
def liquidacion():
    _, alojamientos = db.fetch_all(q.ALOJAMIENTOS)
    id_alojamiento = request.args.get("id_alojamiento", type=int)
    anio = request.args.get("anio", type=int)
    mes = request.args.get("mes", type=int)

    resultado = None
    if id_alojamiento and anio and mes:
        columns, rows = db.fetch_all(
            q.LIQUIDACION_MES,
            {"id_alojamiento": id_alojamiento, "anio": anio, "mes": mes},
        )
        total_facturado = sum(r[3] for r in rows) if rows else 0
        total_pagado = sum(r[4] for r in rows) if rows else 0
        resultado = {
            "columns": columns,
            "rows": rows,
            "total_facturado": total_facturado,
            "total_pagado": total_pagado,
            "saldo": total_facturado - total_pagado,
        }

    return render_template(
        "liquidacion.html",
        alojamientos=alojamientos,
        id_alojamiento=id_alojamiento,
        anio=anio,
        mes=mes,
        resultado=resultado,
    )


# ---------------------------------------------------------------------
# Las 8 consultas de análisis (Entrega 1)
# ---------------------------------------------------------------------
REPORTES = {
    "ocupacion": {
        "titulo": "1. Ocupación por municipio y mes (PIVOT)",
        "sql": q.OCUPACION_PIVOT,
        "descripcion": "% de ocupación = noches vendidas / noches disponibles, por municipio y mes.",
        "necesita_anio": True,
    },
    "ingresos": {
        "titulo": "2. Ingresos por municipio, tipo y temporada (ROLLUP + GROUPING)",
        "sql": q.INGRESOS_ROLLUP,
        "descripcion": "Jerarquía municipio > tipo de alojamiento > temporada, con subtotales.",
        "necesita_anio": True,
    },
    "top3": {
        "titulo": "3. Top 3 alojamientos por municipio (RANK)",
        "sql": q.TOP3_RANK,
        "descripcion": "Los 3 alojamientos de mayor ingreso dentro de cada municipio.",
        "necesita_anio": True,
    },
    "variacion": {
        "titulo": "4. Variación de ingresos mes contra mes (LAG)",
        "sql": q.VARIACION_LAG,
        "descripcion": "Ingreso de cada mes comparado con el mes y el año anterior.",
        "necesita_anio": False,
    },
    "ocupacion-mv": {
        "titulo": "6. Ocupación mensual (vista materializada)",
        "sql": q.OCUPACION_MV,
        "descripcion": "Consulta directa sobre MV_OCUPACION_MENSUAL.",
        "necesita_anio": True,
    },
    "calificaciones": {
        "titulo": "7. Calificaciones por municipio (UNPIVOT)",
        "sql": q.CALIFICACIONES_UNPIVOT,
        "descripcion": "Las 5 dimensiones de reseña, una fila por dimensión.",
        "necesita_anio": False,
    },
    "adr-revpar": {
        "titulo": "8. ADR, RevPAR e índice de estacionalidad (consulta libre)",
        "sql": q.ADR_REVPAR_LIBRE,
        "descripcion": "Qué municipios rinden por precio, por ocupación, o dependen de temporada alta.",
        "necesita_anio": True,
    },
}


@app.route("/consultas/<slug>")
def consulta(slug):
    cfg = REPORTES.get(slug)
    if not cfg:
        return "Consulta no encontrada", 404
    binds = {}
    anio = request.args.get("anio", 2025, type=int)
    if cfg["necesita_anio"]:
        binds["anio"] = anio
    columns, rows = db.fetch_all(cfg["sql"], binds)
    return render_template(
        "report.html",
        title=cfg["titulo"],
        description=cfg["descripcion"],
        columns=columns,
        rows=rows,
        anio=anio if cfg["necesita_anio"] else None,
    )


@app.route("/consultas/rango-fechas")
def consulta_rango_fechas():
    fecha_ini = request.args.get("fecha_ini")
    fecha_fin = request.args.get("fecha_fin")
    columns, rows = [], []
    if fecha_ini and fecha_fin:
        columns, rows = db.fetch_all(
            q.RANGO_FECHAS,
            {
                "fecha_ini": datetime.strptime(fecha_ini, "%Y-%m-%d"),
                "fecha_fin": datetime.strptime(fecha_fin, "%Y-%m-%d"),
            },
        )
    return render_template(
        "rango_fechas.html",
        columns=columns,
        rows=rows,
        fecha_ini=fecha_ini,
        fecha_fin=fecha_fin,
    )


# ---------------------------------------------------------------------
# Auditoría de TARIFA (disparador de sentencia)
# ---------------------------------------------------------------------
@app.route("/auditoria")
def auditoria():
    columns, rows = db.fetch_all(q.AUDITORIA_TARIFA)
    return render_template(
        "report.html",
        title="Auditoría de TARIFA",
        description=(
            "Lo que registra trg_tarifa_auditoria (disparador de sentencia): "
            "quién, cuándo, valor anterior y nuevo."
        ),
        columns=columns,
        rows=rows,
        anio=None,
    )


# ---------------------------------------------------------------------
# Tarifas: editarlas desde aquí dispara trg_tarifa_auditoria en vivo
# ---------------------------------------------------------------------
@app.route("/tarifas")
def tarifas():
    _, alojamientos = db.fetch_all(q.ALOJAMIENTOS)
    id_alojamiento = request.args.get("id_alojamiento", type=int)
    tarifas_rows = []
    if id_alojamiento:
        _, tarifas_rows = db.fetch_all(
            q.TARIFAS_DE_ALOJAMIENTO, {"id_alojamiento": id_alojamiento}
        )
    return render_template(
        "tarifas.html",
        alojamientos=alojamientos,
        id_alojamiento=id_alojamiento,
        tarifas=tarifas_rows,
    )


@app.route("/tarifas/<int:id_tarifa>/editar", methods=["POST"])
def tarifa_editar(id_tarifa):
    id_alojamiento = request.form.get("id_alojamiento", type=int)
    valor = request.form.get(f"valor_noche_{id_tarifa}", type=float)

    if valor is None or valor <= 0:
        flash("El valor de la tarifa debe ser un número positivo.", "danger")
        return redirect(url_for("tarifas", id_alojamiento=id_alojamiento))

    conn = db.get_connection()
    try:
        cur = conn.cursor()
        # UPDATE directo: no hay ningún procedimiento del paquete para esto
        # (no lo exige el PDF), pero es exactamente lo que hace que
        # trg_tarifa_auditoria (disparador de sentencia) escriba una fila
        # en AUDITORIA_TARIFA con el valor anterior y el nuevo.
        cur.execute(
            "UPDATE tarifa SET valor_noche = :valor WHERE id_tarifa = :id_tarifa",
            {"valor": valor, "id_tarifa": id_tarifa},
        )
        conn.commit()
        flash(
            f"Tarifa {id_tarifa} actualizada a ${valor:,.0f}. El cambio ya "
            "quedó registrado en Auditoría de tarifas (trg_tarifa_auditoria).",
            "success",
        )
    except oracledb.DatabaseError as exc:
        conn.rollback()
        flash(f"No se pudo actualizar la tarifa: {exc}", "danger")
    finally:
        conn.close()

    return redirect(url_for("tarifas", id_alojamiento=id_alojamiento))


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)), debug=True)
