# Asistente 3 EA

La versión de riesgo porcentual es `Asistente 3 - TP Fijo.mq5` (v5.40).

## Panel OPERAR

La barra superior muestra cinco cifras que se ven desde cualquier pestaña:

| Celda | Qué muestra |
|-------|-------------|
| RIESGO | Importe objetivo por operación (monto redondeado hacia arriba) |
| SI PIERDE | Pérdida estimada si salta el SL |
| SI GANA | Ganancia estimada si salta el TP |
| EQUIDAD | Equity actual de la cuenta |
| LOTE | Lotaje que se usará en la próxima operación |

La moneda de la cuenta se indica una sola vez, a la derecha de la barra de título. Los importes grandes se
abrevian (`100.0K`, `1.25M`) para que quepan en la celda. El valor de LOTE se pinta en naranja —y con `⚠`—
cuando el broker obliga a usar su lote mínimo o máximo.

Debajo, OPERAR muestra un bloque **informativo** con el riesgo activo (`RIESGO 4% · BASE ...`), el precio
para las órdenes LIMIT con sus botones de ayuda (`USAR ASK`, `USAR BID`, `RESET`) y los botones BUY / SELL / BUY LIMIT / SELL LIMIT. Las pestañas CUENTA, POSIC. y
CONFIG se mantienen.

## Riesgo porcentual

`InpRiskPercent` es el porcentaje que se arriesga por operación (por defecto, 4%). **Solo se puede cambiar
en las Entradas de MetaTrader**: el panel ya no tiene campo editable y los comandos del dashboard
(`set_risk_percent` / `set_risk_usd`) se ignoran con un aviso en el log. El monto objetivo se redondea hacia
arriba a la unidad entera de la moneda de la cuenta (4% de 1,001 = 40.04 → 41); el lote se ajusta hacia abajo
al paso del broker. Si el lote mínimo supera el objetivo, se usa el mínimo y se indica la advertencia
correspondiente.

## Base de cálculo del riesgo

El porcentaje se aplica sobre una **base**, y hay dos modos (`InpRiskBaseMode`):

- **Balance completo** (`RISK_BASE_FULL_BALANCE`, por defecto): la base es el máximo balance histórico de la
  cuenta. Máximo 1,000 → riesgo 40; al llegar a 1,200 → 48; si el balance cae a 1,056 el riesgo sigue siendo
  48 hasta que el balance supere 1,200. El máximo se conserva entre reinicios y entre gráficos de la misma
  cuenta.
- **Capital base** (`RISK_BASE_CAPITAL`): se arriesga sobre un importe fijo, no sobre el balance completo. Con
  `InpBaseCapital = 1500` en una cuenta de 10,000, la base arranca en 1,500 y el riesgo inicial es 60 (4%).
  A partir de ahí **la base crece con todas las ganancias posteriores y nunca baja**: si el balance sube a
  10,300, la base pasa a 1,800 y el riesgo a 72; si después el balance cae a 10,100, la base se queda en
  1,800. Solo toma los 1,500 iniciales del balance, pero capitaliza todo lo que esos 1,500 vayan ganando.

  El balance de referencia se captura la primera vez que el EA corre con ese capital base y se guarda
  (variable global + `Terminal\MQL5\Files\GQP_BASE_*.dat`), de modo que sobrevive a reinicios y cambios de
  gráfico. Se reinicia automáticamente cuando cambias `InpBaseCapital`, o a mano con el botón
  **⟲ Reiniciar base** de la pestaña CONFIG (toma el balance actual como nueva referencia).

  Los depósitos y retiros mueven el balance igual que una ganancia o una pérdida: si haces un depósito
  grande y no quieres que cuente como ganancia de la base, pulsa **⟲ Reiniciar base**.

En CONFIG se puede ver el modo activo, la base actual, el capital base y el balance de referencia; en CUENTA,
la base de riesgo y el lote de la próxima operación.

## Horarios y cierres

En las propiedades del EA (MetaTrader → Entradas):

- `InpUseSessionFilter`: activa el horario de sesión (desactivado de forma predeterminada para no bloquear entradas sin configuración).
- `InpSessionStart` / `InpSessionEnd`: horario diario en hora del servidor del broker, formato `HH:MM`. Fuera de ese horario no permite abrir operaciones nuevas. Al terminar, elimina las órdenes BUY LIMIT y SELL LIMIT creadas por este EA; deja abiertas las posiciones que ya estén activas. Admite sesiones que cruzan medianoche.
- `InpCloseBeforeFridayMarketEnd`: cierra las posiciones de este EA y cancela sus órdenes pendientes LIMIT y STOP (incluidos STOP LIMIT) el viernes.
- `InpFridayCloseMinutes`: por defecto, 30 minutos antes del último cierre de sesión del símbolo publicado por el broker. Si MetaTrader no informa el horario, usa `InpFridayMarketCloseFallback` (por defecto `23:59`, hora del servidor).

Los cierres automáticos solo abarcan el símbolo del gráfico y el `InpMagicNumber` de esta instancia; no modifican operaciones ajenas al EA. El terminal debe permanecer abierto, con el EA activo y el trading algorítmico permitido para que el temporizador ejecute los cierres.

## JSON para el dashboard

El estado exportado (`GQP_*_state.json`) mantiene los campos anteriores y añade los de la base de riesgo:

- `risk_base_mode`: `full_balance` o `capital_base`.
- `risk_base`: base efectiva sobre la que se aplica el porcentaje.
- `risk_base_capital` y `risk_base_start_balance`: capital base configurado y balance de referencia.
- `lots_mode` pasa a `from_capital_base_percent` cuando se usa capital base.
- `expected_loss_percent_risk_base` (el campo `expected_loss_percent_high_water` se mantiene y ahora es
  relativo a la base activa).

El riesgo es de solo lectura para el dashboard: cualquier intento de cambiarlo por comando se ignora.
