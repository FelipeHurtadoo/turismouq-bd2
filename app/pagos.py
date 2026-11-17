"""
TurismoUQ · Pagos en línea con la pasarela simulada.

Flujo de una reserva nueva:
   formulario de reserva -> /pagos/checkout (resumen + datos de pago)
   -> pasarela.py responde APROBADO / RECHAZADO
   -> pkg_transacciones.sp_reservar_y_pagar con esa respuesta
   -> /pagos/resultado

Si la pasarela rechaza, el procedimiento hace ROLLBACK TO sp_antes_pago: la
reserva queda PENDIENTE y se puede pagar después desde /pagos (que llama a
pkg_transacciones.sp_registrar_pago). Si falla la reserva misma, ROLLBACK
TO sp_inicio: no queda nada.
"""

from datetime import datetime

import oracledb
from flask import Blueprint, flash, redirect, render_template, request, session, url_for

import codigo
import db
import pasarela

bp = Blueprint("pagos", __name__, url_prefix="/pagos")


@bp.app_template_filter("pesos")
def pesos(valor):
    """$1.071.000: separador de miles con punto, como se escribe en Colombia."""
    return "$" + f"{float(valor or 0):,.0f}".replace(",", ".")

MAX_HABITACIONES = 6

SQL_RESUMEN_HABITACIONES = """
SELECT h.id_habitacion, h.numero, h.categoria, h.capacidad
  FROM habitacion h WHERE h.id_habitacion = :id"""

SQL_ALOJAMIENTO = """
SELECT a.nombre, m.nombre FROM alojamiento a JOIN municipio m ON m.id_municipio = a.id_municipio
 WHERE a.id_alojamiento = :id"""

SQL_CLIENTE = "SELECT nombres || ' ' || apellidos, email FROM cliente WHERE id_cliente = :id"

SQL_RESERVA = """
SELECT r.id_reserva, r.estado, r.fecha_checkin, r.fecha_checkout, r.num_huespedes,
       r.valor_total,
       NVL((SELECT SUM(p.valor) FROM pago p WHERE p.id_reserva = r.id_reserva AND p.estado = 'APROBADO'), 0) AS pagado,
       c.nombres || ' ' || c.apellidos AS cliente, a.nombre AS alojamiento, m.nombre AS municipio,
       (SELECT LISTAGG(h.numero, ', ') WITHIN GROUP (ORDER BY h.numero)
          FROM reserva_habitacion rh JOIN habitacion h ON h.id_habitacion = rh.id_habitacion
         WHERE rh.id_reserva = r.id_reserva) AS habitaciones,
       r.observaciones
  FROM reserva r
  JOIN cliente c     ON c.id_cliente = r.id_cliente
  JOIN alojamiento a ON a.id_alojamiento = r.id_alojamiento
  JOIN municipio m   ON m.id_municipio = a.id_municipio
 WHERE r.id_reserva = :id"""

SQL_PAGOS_DE_RESERVA = """
SELECT id_pago, fecha_pago, valor, medio_pago, estado, referencia
  FROM pago WHERE id_reserva = :id ORDER BY id_pago"""

SQL_PENDIENTES = """
SELECT * FROM (
   SELECT r.id_reserva, c.nombres || ' ' || c.apellidos AS cliente, a.nombre AS alojamiento,
          r.fecha_checkin, r.fecha_checkout, r.valor_total,
          r.valor_total - NVL((SELECT SUM(p.valor) FROM pago p
                                WHERE p.id_reserva = r.id_reserva AND p.estado = 'APROBADO'), 0) AS saldo
     FROM reserva r
     JOIN cliente c ON c.id_cliente = r.id_cliente
     JOIN alojamiento a ON a.id_alojamiento = r.id_alojamiento
    WHERE r.estado = 'PENDIENTE')
 WHERE saldo > 0
 ORDER BY id_reserva DESC
 FETCH FIRST 25 ROWS ONLY"""

SQL_PAGOS_PASARELA = """
SELECT p.id_pago, p.id_reserva, p.fecha_pago, p.valor, p.medio_pago, p.referencia, r.estado
  FROM pago p JOIN reserva r ON r.id_reserva = p.id_reserva
 WHERE p.referencia LIKE 'TUQ-%'
 ORDER BY p.id_pago DESC
 FETCH FIRST 15 ROWS ONLY"""

PLSQL_RESERVAR_Y_PAGAR = """
DECLARE
   v_habs pkg_transacciones.t_lista_habitaciones;
   v_idx  PLS_INTEGER := 0;
   v_res  VARCHAR2(20);
BEGIN
{lineas}
   pkg_transacciones.sp_reservar_y_pagar(
      p_id_cliente         => :id_cliente,
      p_id_alojamiento     => :id_alojamiento,
      p_fecha_checkin      => :checkin,
      p_fecha_checkout     => :checkout,
      p_num_huespedes      => :huespedes,
      p_habitaciones       => v_habs,
      p_valor_pago         => :valor,
      p_medio_pago         => :medio,
      p_id_reserva         => :id_reserva,
      p_resultado          => v_res,
      p_canal              => :canal,
      p_observaciones      => :obs,
      p_respuesta_pasarela => :respuesta,
      p_referencia         => :referencia,
      p_detalle_pasarela   => :detalle);
   :resultado := v_res;
END;"""

PLSQL_REGISTRAR_PAGO = """
DECLARE
   v_res VARCHAR2(20);
   v_msg VARCHAR2(400);
BEGIN
   pkg_transacciones.sp_registrar_pago(
      p_id_reserva         => :id_reserva,
      p_valor_pago         => :valor,
      p_medio_pago         => :medio,
      p_resultado          => v_res,
      p_mensaje            => v_msg,
      p_respuesta_pasarela => :respuesta,
      p_referencia         => :referencia,
      p_detalle_pasarela   => :detalle);
   :resultado := v_res;
   :mensaje   := v_msg;
END;"""


def _ora(exc):
    return str(exc.args[0].message).split("\n")[0].strip()


# ---------------------------------------------------------------------
# Panel de pagos
# ---------------------------------------------------------------------
@bp.route("/")
def panel():
    _, pendientes = db.fetch_all(SQL_PENDIENTES)
    _, recientes = db.fetch_all(SQL_PAGOS_PASARELA)
    return render_template("pagos_panel.html", pendientes=pendientes, recientes=recientes)


# ---------------------------------------------------------------------
# Checkout: armar el pedido (reserva nueva o saldo de una existente)
# ---------------------------------------------------------------------
@bp.route("/checkout", methods=["POST"])
def checkout_desde_reserva():
    """Recibe el formulario de Nueva reserva, calcula el valor con
    fn_valor_estadia y deja el pedido en la sesión. Todavía no se graba
    nada en la base: la reserva y el pago se crean juntos al pagar."""
    form = request.form
    habitaciones = request.form.getlist("habitaciones", type=int)[:MAX_HABITACIONES]
    try:
        checkin = datetime.strptime(form.get("checkin", ""), "%Y-%m-%d")
        checkout = datetime.strptime(form.get("checkout", ""), "%Y-%m-%d")
    except ValueError:
        flash("Completa las fechas de check-in y check-out.", "danger")
        return redirect(url_for("reserva_nueva"))
    if not form.get("id_cliente") or not habitaciones:
        flash("Elige un cliente y al menos una habitación antes de pagar.", "danger")
        return redirect(url_for("reserva_nueva"))

    conn = db.get_connection()
    try:
        cur = conn.cursor()
        lineas, total = [], 0
        for hab in habitaciones:
            try:
                valor = cur.callfunc("pkg_turismo.fn_valor_estadia", oracledb.NUMBER,
                                     [hab, checkin, checkout])
            except oracledb.DatabaseError as exc:
                flash(f"No se pudo calcular el valor de la habitación {hab}: {_ora(exc)}", "danger")
                return redirect(url_for("reserva_nueva"))
            _, numero, categoria, capacidad = cur.execute(SQL_RESUMEN_HABITACIONES, {"id": hab}).fetchone()
            lineas.append({"id": hab, "numero": numero, "categoria": categoria,
                           "capacidad": capacidad, "valor": float(valor)})
            total += float(valor)
        aloj, municipio = cur.execute(SQL_ALOJAMIENTO, {"id": int(form["id_alojamiento"])}).fetchone()
        cliente, email = cur.execute(SQL_CLIENTE, {"id": int(form["id_cliente"])}).fetchone()
    finally:
        conn.close()

    session["pedido"] = {
        "tipo": "nueva",
        "id_cliente": int(form["id_cliente"]), "cliente": cliente, "email": email,
        "id_alojamiento": int(form["id_alojamiento"]), "alojamiento": aloj, "municipio": municipio,
        "checkin": checkin.strftime("%Y-%m-%d"), "checkout": checkout.strftime("%Y-%m-%d"),
        "noches": (checkout - checkin).days,
        "huespedes": int(form.get("huespedes") or 1), "canal": form.get("canal", "WEB"),
        "lineas": lineas, "total": total,
    }
    return redirect(url_for("pagos.checkout"))


@bp.route("/reserva/<int:id_reserva>")
def pagar_saldo(id_reserva):
    """Pedido para pagar el saldo de una reserva que ya existe."""
    columnas, filas = db.fetch_all(SQL_RESERVA, {"id": id_reserva})
    if not filas:
        flash(f"No existe la reserva {id_reserva}.", "danger")
        return redirect(url_for("pagos.panel"))
    r = dict(zip([c.lower() for c in columnas], filas[0]))
    saldo = float(r["valor_total"]) - float(r["pagado"])
    if saldo <= 0:
        flash(f"La reserva {id_reserva} no tiene saldo pendiente.", "info")
        return redirect(url_for("pagos.panel"))
    session["pedido"] = {
        "tipo": "saldo", "id_reserva": id_reserva,
        "cliente": r["cliente"], "alojamiento": r["alojamiento"], "municipio": r["municipio"],
        "checkin": r["fecha_checkin"].strftime("%Y-%m-%d"),
        "checkout": r["fecha_checkout"].strftime("%Y-%m-%d"),
        "noches": (r["fecha_checkout"] - r["fecha_checkin"]).days,
        "huespedes": r["num_huespedes"], "habitaciones": r["habitaciones"],
        "valor_total": float(r["valor_total"]), "pagado": float(r["pagado"]),
        "total": saldo,
    }
    return redirect(url_for("pagos.checkout"))


@bp.route("/checkout")
def checkout():
    pedido = session.get("pedido")
    if not pedido:
        return redirect(url_for("pagos.panel"))
    return render_template("pagos_checkout.html", pedido=pedido,
                           tarjetas=pasarela.TARJETAS_PRUEBA, bancos=pasarela.BANCOS_PSE)


# ---------------------------------------------------------------------
# Procesar: pasarela -> procedimiento almacenado
# ---------------------------------------------------------------------
@bp.route("/procesar", methods=["POST"])
def procesar():
    pedido = session.get("pedido")
    if not pedido:
        return redirect(url_for("pagos.panel"))

    f = request.form
    try:
        if f.get("metodo") == "pse":
            respuesta = pasarela.autorizar_pse(f.get("banco"), f.get("titular_pse"))
        else:
            respuesta = pasarela.autorizar_tarjeta(f.get("numero"), f.get("vencimiento"),
                                                   f.get("cvv"), f.get("titular"),
                                                   f.get("tipo_tarjeta", "credito"))
    except pasarela.DatosInvalidos as exc:
        flash(str(exc), "danger")
        return redirect(url_for("pagos.checkout"))

    valor = pedido["total"]
    if pedido["tipo"] == "saldo" and f.get("valor_abono"):
        try:
            valor = float(f.get("valor_abono"))
        except ValueError:
            pass

    conn = db.get_connection()
    try:
        cur = conn.cursor()
        if pedido["tipo"] == "nueva":
            resultado = _pagar_reserva_nueva(cur, pedido, respuesta, valor)
        else:
            resultado = _pagar_saldo(cur, pedido, respuesta, valor)
    finally:
        conn.close()

    session.pop("pedido", None)
    session["resultado_pago"] = resultado
    return redirect(url_for("pagos.resultado"))


def _pagar_reserva_nueva(cur, pedido, respuesta, valor):
    lineas, binds = [], {}
    for i, linea in enumerate(pedido["lineas"], start=1):
        binds[f"h{i}"] = linea["id"]
        lineas.append(f"   v_idx := v_idx + 1; v_habs(v_idx) := :h{i};")
    id_var, res_var = cur.var(oracledb.NUMBER), cur.var(str)
    binds.update({
        "id_cliente": pedido["id_cliente"], "id_alojamiento": pedido["id_alojamiento"],
        "checkin": datetime.strptime(pedido["checkin"], "%Y-%m-%d"),
        "checkout": datetime.strptime(pedido["checkout"], "%Y-%m-%d"),
        "huespedes": pedido["huespedes"], "valor": valor, "medio": respuesta["medio_pago"],
        "id_reserva": id_var, "resultado": res_var, "canal": pedido["canal"],
        "obs": f"Pago en línea · {respuesta['descripcion']}",
        "respuesta": respuesta["respuesta"], "referencia": respuesta["referencia"],
        "detalle": respuesta["motivo"],
    })
    salida = {"tipo": "nueva", "pasarela": respuesta, "valor": valor}
    try:
        cur.execute(PLSQL_RESERVAR_Y_PAGAR.format(lineas="\n".join(lineas)), binds)
        salida["id_reserva"] = int(id_var.getvalue())
        salida["resultado_bd"] = res_var.getvalue()     # PAGADA / PENDIENTE_PAGO
    except oracledb.DatabaseError as exc:
        # Falló la reserva (habitación tomada, capacidad...): ROLLBACK TO
        # sp_inicio dentro del procedimiento. No hay nada que cobrar.
        salida["error_reserva"] = _ora(exc)
    return salida


def _pagar_saldo(cur, pedido, respuesta, valor):
    res_var, msg_var = cur.var(str), cur.var(str, 400)
    salida = {"tipo": "saldo", "pasarela": respuesta, "valor": valor, "id_reserva": pedido["id_reserva"]}
    try:
        cur.execute(PLSQL_REGISTRAR_PAGO, {
            "id_reserva": pedido["id_reserva"], "valor": valor, "medio": respuesta["medio_pago"],
            "respuesta": respuesta["respuesta"], "referencia": respuesta["referencia"],
            "detalle": respuesta["motivo"], "resultado": res_var, "mensaje": msg_var,
        })
        salida["resultado_bd"] = res_var.getvalue()     # PAGADA / ABONO / RECHAZADO
        salida["mensaje_bd"] = msg_var.getvalue()
    except oracledb.DatabaseError as exc:
        salida["error_reserva"] = _ora(exc)
    return salida


@bp.route("/resultado")
def resultado():
    res = session.get("resultado_pago")
    if not res:
        return redirect(url_for("pagos.panel"))
    reserva = pagos = None
    if res.get("id_reserva"):
        columnas, filas = db.fetch_all(SQL_RESERVA, {"id": res["id_reserva"]})
        if filas:
            reserva = dict(zip([c.lower() for c in columnas], filas[0]))
        _, pagos = db.fetch_all(SQL_PAGOS_DE_RESERVA, {"id": res["id_reserva"]})
    proc = "sp_reservar_y_pagar" if res.get("tipo") == "nueva" else "sp_registrar_pago"
    return render_template("pagos_resultado.html", res=res, reserva=reserva, pagos=pagos,
                           codigo_proc=codigo.procedimiento("PKG_TRANSACCIONES", proc))
