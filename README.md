# Asistente 3 EA

La versión de riesgo porcentual es `Asistente 3 - TP Fijo.mq5` (v5.30).

## Panel OPERAR

El panel principal se redujo a tres cifras —riesgo objetivo, pérdida estimada al SL y ganancia estimada al TP—, un campo para ajustar el riesgo, el precio de las órdenes limit y los botones BUY / SELL / BUY LIMIT / SELL LIMIT. Las pestañas CUENTA, POSIC. y CONFIG se mantienen.

## Riesgo porcentual

`InpRiskPercent` es el porcentaje del máximo balance histórico que se arriesga por operación (por defecto, 4%); se puede cambiar en las Entradas de MetaTrader o en el campo de riesgo de OPERAR. Por ejemplo: balance máximo de 1,000 → riesgo objetivo 40; al llegar a 1,200 → 48. Si el balance luego cae a 1,056, el riesgo sigue siendo 48 hasta que el balance supere 1,200. El máximo se conserva entre reinicios y entre gráficos de la misma cuenta. El monto objetivo se redondea hacia arriba a la unidad entera de la moneda de la cuenta (4% de 1,001 = 40.04 → 41); el lote se ajusta hacia abajo al paso del broker. Si el lote mínimo supera el objetivo, se usa el mínimo y se indica la advertencia correspondiente.

## Horarios y cierres

En las propiedades del EA (MetaTrader → Entradas):

- `InpUseSessionFilter`: activa el horario de sesión (desactivado de forma predeterminada para no bloquear entradas sin configuración).
- `InpSessionStart` / `InpSessionEnd`: horario diario en hora del servidor del broker, formato `HH:MM`. Fuera de ese horario no permite abrir operaciones nuevas. Al terminar, elimina las órdenes BUY LIMIT y SELL LIMIT creadas por este EA; deja abiertas las posiciones que ya estén activas. Admite sesiones que cruzan medianoche.
- `InpCloseBeforeFridayMarketEnd`: cierra las posiciones de este EA y cancela sus órdenes pendientes LIMIT y STOP (incluidos STOP LIMIT) el viernes.
- `InpFridayCloseMinutes`: por defecto, 30 minutos antes del último cierre de sesión del símbolo publicado por el broker. Si MetaTrader no informa el horario, usa `InpFridayMarketCloseFallback` (por defecto `23:59`, hora del servidor).

Los cierres automáticos solo abarcan el símbolo del gráfico y el `InpMagicNumber` de esta instancia; no modifican operaciones ajenas al EA. El terminal debe permanecer abierto, con el EA activo y el trading algorítmico permitido para que el temporizador ejecute los cierres.
