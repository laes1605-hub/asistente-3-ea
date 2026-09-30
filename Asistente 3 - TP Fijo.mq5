//+------------------------------------------------------------------+
//|                  Asistente 3 - TP Fijo.mq5                       |
//|                                                                  |
//|   Copia del Asistente 3 (v4.31) con 3 cambios:                   |
//|     1) Cierre DIRECTO por TP: no hay trailing stop ni gestion    |
//|        1:2, el SL nunca se mueve y la operacion cierra solo al   |
//|        tocar TP o SL.                                            |
//|     2) Sin tabla de lotajes por niveles: UN SOLO lotaje por par, |
//|        editable desde el panel, desde los inputs o el dashboard. |
//|     3) El panel muestra cuanto GANARIAS (con el TP del asistente)|
//|        y cuanto PERDERIAS (con el SL del asistente), en dinero y |
//|        en % del balance, por operacion y para las posiciones.    |
//|   Del resto, igual que el original: linea de limite, split de    |
//|   lotes, enforce de SL/TP, JSON para el dashboard, persistencia  |
//|   y tabs OPERAR / CUENTA / POSIC / CONFIG.                       |
//+------------------------------------------------------------------+
#property copyright "Gestión Cuantitativa EA"
#property version   "5.00"
#property strict

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== STOP LOSS / TAKE PROFIT ==="
input double InpSL_Points        = 95;      // Stop Loss en puntos (fijo, sin trailing)
input double InpTP_Points        = 305;     // Take Profit en puntos (cierre directo)

input group "=== LOTAJE ÚNICO POR PAR ==="
input double InpLots             = 0.01;    // Lotaje (editable también desde el panel)

input group "=== SPLIT DE LOTES ==="
input double InpMaxLotsPerOrder  = 100.0;
input int    InpSplitDelayMs     = 200;

input group "=== CONFIGURACIÓN ==="
input int    InpPanelX      = 20;
input int    InpPanelY      = 50;
input long   InpMagicNumber = 123456;
input string InpComment     = "QA_EA";

//+------------------------------------------------------------------+
//| CONSTANTES                                                       |
//+------------------------------------------------------------------+
#define PNL_W        320
#define PNL_H        466
#define TAB_H        28
#define CONTENT_Y0   96
#define CONTENT_H    (PNL_H - CONTENT_Y0 - 6)

#define TAB_OPERAR   0
#define TAB_CUENTA   1
#define TAB_POSIC    2
#define TAB_CONFIG   3
#define N_TABS       4

#define LINE_LIMIT_NAME   "GQP_LIMIT_LINE"
#define LINE_LIMIT_LABEL  "GQP_LIMIT_LABEL"
#define LINE_LIMIT_SL     "GQP_LIMIT_SL"
#define LINE_LIMIT_TP     "GQP_LIMIT_TP"
#define EDIT_PRICE_NAME   "GQP_EDITPRICE"
#define EDIT_LOT_NAME     "GQP_EDITLOT"

#define GV_PREFIX         "GQP_"
string GV_LOTS;
string GV_LOTS_INP;
string GV_LIMIT_PRICE;

//+------------------------------------------------------------------+
//| NOMBRES DE ARCHIVOS COMPARTIDOS                                 |
//+------------------------------------------------------------------+
string g_StateFileName;   // EA escribe → Python lee
string g_CmdFileName;     // Python escribe → EA lee

//+------------------------------------------------------------------+
//| ESTRUCTURA DE TRADE                                             |
//+------------------------------------------------------------------+
struct TradeRecord
{
   ulong  ticket;
   bool   isPending;
   int    orderType;
   double lots;
   double openPrice;
   double sl;
   double tp;
   double profit;
   ulong  splitGroupId;
};

//+------------------------------------------------------------------+
//| GLOBALES                                                         |
//+------------------------------------------------------------------+
int         ActiveTab      = TAB_OPERAR;
double      SL_Points;
double      TP_Points;
double      g_Lots         = 0.01;
double      g_LimitPrice   = 0.0;

TradeRecord g_Trades[];
int         g_TradeCount   = 0;
int         g_ScrollOffset = 0;
int         g_SaveCounter  = 0;
int         g_ExportCounter = 0;
TradeRecord g_ClosedQueue[];

string PFX     = "GQP_";
string PFX_OP  = "GQP_OP_";
string PFX_ACC = "GQP_ACC_";
string PFX_POS = "GQP_POS_";
string PFX_CFG = "GQP_CFG_";

string TAB_NAMES[N_TABS];

#define OBJ_TITLE        "GQP_TITLE"
#define OBJ_INFOBAR_LOT  "GQP_IB_LOT"
#define OBJ_INFOBAR_RR   "GQP_IB_RR"
#define OBJ_INFOBAR_PL   "GQP_IB_PL"
#define OBJ_INFOBAR_EQ   "GQP_IB_EQ"

int PNL_X, PNL_Y;

//+------------------------------------------------------------------+
//| FORWARD DECLARATIONS                                             |
//+------------------------------------------------------------------+
void RebuildActiveTab();
void UpdateInfoBar();
void UpdateLimitLine();
void RemoveLimitLine();
void DeleteContentObjects();
void BuildTabOperar();
void BuildTabCuenta();
void BuildTabPosiciones();
void BuildTabConfig();
void RefreshTabBar();
void SyncAllTrades();
void ApplyLots(double v);
void LogClosedTrade(const TradeRecord &rec);
void FlushClosedQueue();
void SaveState();
void ExportStateToFile();

//+------------------------------------------------------------------+
//| INICIALIZAR NOMBRES DE ARCHIVOS COMPARTIDOS                     |
//+------------------------------------------------------------------+
void InitSharedFileNames()
{
   long login = AccountInfoInteger(ACCOUNT_LOGIN);
   string sym = _Symbol;
   string mag = IntegerToString(InpMagicNumber);

   g_StateFileName = "GQP_" + IntegerToString(login) + "_" + sym + "_" + mag + "_state.json";
   g_CmdFileName   = "GQP_" + IntegerToString(login) + "_" + sym + "_" + mag + "_cmd.json";

   Print("📁 Archivo de estado: ", g_StateFileName);
   Print("📁 Archivo de comandos: ", g_CmdFileName);
   Print("📁 Carpeta Common Files: Terminal\\Common\\Files\\");
}

//+------------------------------------------------------------------+
//| EXPORTAR ESTADO A ARCHIVO JSON (EA → Python)                    |
//+------------------------------------------------------------------+
void ExportStateToFile()
{
   int handle = FileOpen(g_StateFileName, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
   {
      Print("❌ Error al escribir archivo de estado: ", GetLastError());
      return;
   }

   string json = "{\n";
   json += "  \"symbol\": \"" + _Symbol + "\",\n";
   json += "  \"magic\": " + IntegerToString(InpMagicNumber) + ",\n";
   json += "  \"login\": " + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ",\n";
   json += "  \"broker\": \"" + AccountInfoString(ACCOUNT_COMPANY) + "\",\n";
   json += "  \"server\": \"" + AccountInfoString(ACCOUNT_SERVER) + "\",\n";
   json += "  \"version\": \"5.00\",\n";
   json += "  \"close_mode\": \"TP_FIJO_SIN_TRAILING\",\n";

   // Estado
   json += "  \"lots\": " + DoubleToString(g_Lots, 2) + ",\n";
   json += "  \"lots_mode\": \"fixed\",\n";
   json += "  \"limit_price\": " + DoubleToString(g_LimitPrice, 8) + ",\n";
   json += "  \"trailing_stop\": false,\n";

   // Parámetros
   json += "  \"sl_points\": " + DoubleToString(SL_Points, 1) + ",\n";
   json += "  \"tp_points\": " + DoubleToString(TP_Points, 1) + ",\n";
   json += "  \"max_lots_per_order\": " + DoubleToString(InpMaxLotsPerOrder, 1) + ",\n";
   json += "  \"split_delay_ms\": " + IntegerToString(InpSplitDelayMs) + ",\n";

   // Proyección con el SL / TP del asistente
   json += "  \"expected_loss\": " + DoubleToString(CalcRiskDollars(g_Lots), 2) + ",\n";
   json += "  \"expected_gain\": " + DoubleToString(CalcProfitDollars(g_Lots), 2) + ",\n";
   json += "  \"risk_percent_balance\": " + DoubleToString(RiskPercentBalance(g_Lots), 2) + ",\n";

   // Cuenta
   json += "  \"balance\": " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + ",\n";
   json += "  \"equity\": " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + ",\n";
   json += "  \"margin\": " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN), 2) + ",\n";
   json += "  \"free_margin\": " + DoubleToString(AccountInfoDouble(ACCOUNT_FREEMARGIN), 2) + ",\n";
   json += "  \"currency\": \"" + AccountInfoString(ACCOUNT_CURRENCY) + "\",\n";

   // Precios
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   json += "  \"ask\": " + DoubleToString(ask, digits) + ",\n";
   json += "  \"bid\": " + DoubleToString(bid, digits) + ",\n";
   json += "  \"digits\": " + IntegerToString(digits) + ",\n";
   json += "  \"point\": " + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_POINT), 10) + ",\n";

   // Posiciones
   json += "  \"positions\": [";
   bool firstPos = true;
   for(int i = 0; i < g_TradeCount; i++)
   {
      if(g_Trades[i].isPending) continue;
      if(!firstPos) json += ", ";
      firstPos = false;
      json += "\n    {";
      json += "\"ticket\": " + IntegerToString(g_Trades[i].ticket);
      json += ", \"type\": \"" + (g_Trades[i].orderType == 0 ? "BUY" : "SELL") + "\"";
      json += ", \"lots\": " + DoubleToString(g_Trades[i].lots, 2);
      json += ", \"open_price\": " + DoubleToString(g_Trades[i].openPrice, digits);
      json += ", \"sl\": " + DoubleToString(g_Trades[i].sl, digits);
      json += ", \"tp\": " + DoubleToString(g_Trades[i].tp, digits);
      json += ", \"profit\": " + DoubleToString(g_Trades[i].profit, 2);
      json += ", \"gain_if_tp\": " + DoubleToString(TradeGainIfTP(g_Trades[i]), 2);
      json += ", \"loss_if_sl\": " + DoubleToString(TradeLossIfSL(g_Trades[i]), 2);
      json += "}";
   }
   json += "\n  ],\n";

   // Órdenes pendientes
   json += "  \"pending\": [";
   bool firstPend = true;
   for(int i = 0; i < g_TradeCount; i++)
   {
      if(!g_Trades[i].isPending) continue;
      if(!firstPend) json += ", ";
      firstPend = false;
      string otName = "PENDING";
      switch(g_Trades[i].orderType)
      {
         case ORDER_TYPE_BUY_LIMIT:  otName = "BUY_LIMIT"; break;
         case ORDER_TYPE_SELL_LIMIT: otName = "SELL_LIMIT"; break;
         case ORDER_TYPE_BUY_STOP:   otName = "BUY_STOP"; break;
         case ORDER_TYPE_SELL_STOP:  otName = "SELL_STOP"; break;
      }
      json += "\n    {";
      json += "\"ticket\": " + IntegerToString(g_Trades[i].ticket);
      json += ", \"type\": \"" + otName + "\"";
      json += ", \"lots\": " + DoubleToString(g_Trades[i].lots, 2);
      json += ", \"price\": " + DoubleToString(g_Trades[i].openPrice, digits);
      json += ", \"sl\": " + DoubleToString(g_Trades[i].sl, digits);
      json += ", \"tp\": " + DoubleToString(g_Trades[i].tp, digits);
      json += ", \"gain_if_tp\": " + DoubleToString(TradeGainIfTP(g_Trades[i]), 2);
      json += ", \"loss_if_sl\": " + DoubleToString(TradeLossIfSL(g_Trades[i]), 2);
      json += "}";
   }
   json += "\n  ],\n";

   // Timestamp
   json += "  \"updated_at\": \"" + TimeToString(TimeCurrent()) + "\"\n";
   json += "}";

   FileWriteString(handle, json);
   FileClose(handle);
}

//+------------------------------------------------------------------+
//| LEER COMANDOS DESDE ARCHIVO JSON (Python → EA)                  |
//+------------------------------------------------------------------+
void ReadCommandsFromFile()
{
   if(!FileIsExist(g_CmdFileName, FILE_COMMON)) return;

   int handle = FileOpen(g_CmdFileName, FILE_READ | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE) return;

   string content = "";
   while(!FileIsEnding(handle))
      content += FileReadString(handle);
   FileClose(handle);

   if(StringLen(content) < 5)
   {
      FileDelete(g_CmdFileName, FILE_COMMON);
      return;
   }

   bool changed = false;

   // ── Parsear SL ───────────────────────────────
   double newSL = ExtractJsonDouble(content, "set_sl_points");
   if(newSL > 0 && newSL != SL_Points)
   {
      SL_Points = newSL;
      Print("📱 Dashboard cambió SL a: ", SL_Points);
      changed = true;
   }

   // ── Parsear TP ───────────────────────────────
   double newTP = ExtractJsonDouble(content, "set_tp_points");
   if(newTP > 0 && newTP != TP_Points)
   {
      TP_Points = newTP;
      Print("📱 Dashboard cambió TP a: ", TP_Points);
      changed = true;
   }

   // ── Parsear Lotaje único ─────────────────────
   double newLots = ExtractJsonDouble(content, "set_lots");
   if(newLots <= 0) newLots = ExtractJsonDouble(content, "set_lot");
   if(newLots > 0 && MathAbs(newLots - g_Lots) > 0.0000001)
   {
      g_Lots = NormalizeLots(newLots);
      GlobalVariableSet(GV_LOTS, g_Lots);
      Print("📱 Dashboard cambió Lotaje a: ", g_Lots);
      changed = true;
   }

   // ── Parsear Precio límite ────────────────────
   double newLim = ExtractJsonDouble(content, "set_limit_price");
   if(newLim > 0 && MathAbs(newLim - g_LimitPrice) > SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 0.5)
   {
      g_LimitPrice = NormalizeDouble(newLim, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      GlobalVariableSet(GV_LIMIT_PRICE, g_LimitPrice);
      UpdateLimitLine();
      Print("📱 Dashboard cambió Precio límite a: ", g_LimitPrice);
      changed = true;
   }

   // ── Borrar archivo de comandos ───────────────
   FileDelete(g_CmdFileName, FILE_COMMON);

   if(changed)
   {
      SaveState();
      ExportStateToFile();
      RebuildActiveTab();
      UpdateInfoBar();
   }
}

//+------------------------------------------------------------------+
//| EXTRAER VALOR NUMÉRICO DE JSON SIMPLE                           |
//+------------------------------------------------------------------+
double ExtractJsonDouble(string json, string key)
{
   string searchKey = "\"" + key + "\"";
   int idx = StringFind(json, searchKey);
   if(idx < 0) return -1;

   int colonIdx = StringFind(json, ":", idx + StringLen(searchKey));
   if(colonIdx < 0) return -1;

   // Encontrar el inicio del valor (saltar espacios)
   int valStart = colonIdx + 1;
   while(valStart < StringLen(json) && StringGetCharacter(json, valStart) == ' ')
      valStart++;

   // Encontrar el fin del valor (hasta coma, llave o fin de línea)
   int valEnd = valStart;
   while(valEnd < StringLen(json))
   {
      int ch = StringGetCharacter(json, valEnd);
      if(ch == ',' || ch == '}' || ch == '\n' || ch == '\r')
         break;
      valEnd++;
   }

   string valStr = StringSubstr(json, valStart, valEnd - valStart);
   StringTrimLeft(valStr);
   StringTrimRight(valStr);

   // Ignorar valores booleanos y strings
   if(valStr == "true" || valStr == "false" || StringGetCharacter(valStr, 0) == '"')
      return -1;

   return StringToDouble(valStr);
}

//+------------------------------------------------------------------+
//| PERSISTENCIA — CLAVES                                           |
//+------------------------------------------------------------------+
void InitGlobalVarKeys()
{
   string suffix  = _Symbol + "_" + IntegerToString(InpMagicNumber);
   GV_LOTS       = GV_PREFIX + "LOTS_"  + suffix;
   GV_LOTS_INP   = GV_PREFIX + "LOTSIN_" + suffix;
   GV_LIMIT_PRICE = GV_PREFIX + "LIMIT_" + suffix;
}

void SaveState()
{
   GlobalVariableSet(GV_LOTS,        g_Lots);
   GlobalVariableSet(GV_LOTS_INP,    InpLots);
   GlobalVariableSet(GV_LIMIT_PRICE, g_LimitPrice);
   SaveStateToFile();
}

void LoadState()
{
   // Lotaje: el valor del panel manda, salvo que el usuario haya cambiado
   // el input InpLots (en ese caso se re-aplica el input).
   bool loadedGV = false;
   if(GlobalVariableCheck(GV_LOTS) && GlobalVariableCheck(GV_LOTS_INP))
   {
      double savedInput = GlobalVariableGet(GV_LOTS_INP);
      if(MathAbs(savedInput - InpLots) < 0.0000001)
      {
         double v = GlobalVariableGet(GV_LOTS);
         if(v > 0) { g_Lots = NormalizeLots(v); loadedGV = true; }
      }
   }
   if(!loadedGV)
   {
      if(InpLots > 0) g_Lots = NormalizeLots(InpLots);
      else            g_Lots = NormalizeLots(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
   }

   if(GlobalVariableCheck(GV_LIMIT_PRICE))
   {
      double lp = GlobalVariableGet(GV_LIMIT_PRICE);
      if(lp > 0.0) g_LimitPrice = lp;
   }

   // Respaldo en disco (por si se reinicia la terminal y se pierden los GV)
   if(!loadedGV && LoadStateFromFile())
      Print("✅ Estado restaurado desde archivo de respaldo");
   else
      Print("ℹ Lotaje activo: ", DoubleToString(g_Lots, 2), " (", _Symbol, ")");
}

string GetStateFileName()
{
   return "GQP_" + _Symbol + "_" + IntegerToString(InpMagicNumber) + ".dat";
}

void SaveStateToFile()
{
   string fname  = GetStateFileName();
   int    handle = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE) return;
   FileWriteString(handle, "LOTS="        + DoubleToString(g_Lots, 2) + "\n");
   FileWriteString(handle, "LIMIT_PRICE=" + DoubleToString(g_LimitPrice, 8) + "\n");
   FileWriteString(handle, "SYMBOL="      + _Symbol + "\n");
   FileWriteString(handle, "MAGIC="       + IntegerToString(InpMagicNumber) + "\n");
   FileWriteString(handle, "SAVED_AT="    + TimeToString(TimeCurrent()) + "\n");
   FileClose(handle);
}

bool LoadStateFromFile()
{
   string fname = GetStateFileName();
   if(!FileIsExist(fname)) return false;
   int handle = FileOpen(fname, FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE) return false;
   bool loaded = false;
   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      StringTrimLeft(line); StringTrimRight(line);
      if(StringLen(line) == 0) continue;
      int sep = StringFind(line, "=");
      if(sep < 0) continue;
      string key = StringSubstr(line, 0, sep);
      string val = StringSubstr(line, sep + 1);
      if(key == "LOTS")
      {
         double v = StringToDouble(val);
         if(v > 0.0) { g_Lots = NormalizeLots(v); loaded = true; }
      }
      else if(key == "LIMIT_PRICE")
      {
         double lp = StringToDouble(val);
         if(lp > 0.0) g_LimitPrice = lp;
      }
   }
   FileClose(handle);
   return loaded;
}

//+------------------------------------------------------------------+
//| CÁLCULOS                                                        |
//+------------------------------------------------------------------+
double ValuePerPoint()
{
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0) return 0.0;
   return (point / tickSize) * tickValue;
}

double MoneyFromPoints(double points, double lots)
{
   return NormalizeDouble(points * ValuePerPoint() * lots, 2);
}

double CalcRiskDollars(double lots)
{
   return MoneyFromPoints(SL_Points, lots);
}

double CalcProfitDollars(double lots)
{
   return MoneyFromPoints(TP_Points, lots);
}

double RiskPercentBalance(double lots)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0) return 0.0;
   return (CalcRiskDollars(lots) / balance) * 100.0;
}

// Ganancia si la posición/orden llega al TP
double TradeGainIfTP(const TradeRecord &tr)
{
   if(tr.tp <= 0 || tr.openPrice <= 0) return 0.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 0.0;
   double pts = (tr.orderType == POSITION_TYPE_BUY || tr.orderType == ORDER_TYPE_BUY_LIMIT ||
                 tr.orderType == ORDER_TYPE_BUY_STOP) ? (tr.tp - tr.openPrice) / point
                                                      : (tr.openPrice - tr.tp) / point;
   if(pts < 0) pts = 0;
   return MoneyFromPoints(pts, tr.lots);
}

// Pérdida si la posición/orden llega al SL
double TradeLossIfSL(const TradeRecord &tr)
{
   if(tr.sl <= 0 || tr.openPrice <= 0) return 0.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(point <= 0) return 0.0;
   double pts = (tr.orderType == POSITION_TYPE_BUY || tr.orderType == ORDER_TYPE_BUY_LIMIT ||
                 tr.orderType == ORDER_TYPE_BUY_STOP) ? (tr.openPrice - tr.sl) / point
                                                      : (tr.sl - tr.openPrice) / point;
   if(pts < 0) pts = 0;
   return MoneyFromPoints(pts, tr.lots);
}

double MidPrice()
{
   return (SymbolInfoDouble(_Symbol,SYMBOL_ASK) +
           SymbolInfoDouble(_Symbol,SYMBOL_BID)) / 2.0;
}

double MidPriceNorm()
{
   return NormalizeDouble(MidPrice(),(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS));
}

string AcctCur()
{
   return AccountInfoString(ACCOUNT_CURRENCY);
}

// Ajusta el lotaje a las reglas del símbolo (min / max / step)
double NormalizeLots(double v)
{
   double minLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;
   if(minLot  <= 0) minLot  = 0.01;
   if(maxLot  <= 0) maxLot  = 100.0;
   v = NormalizeDouble(MathFloor(v / stepLot + 0.5) * stepLot, 2);
   if(v < minLot) v = minLot;
   if(v > maxLot) v = maxLot;
   return v;
}

void ApplyLots(double v)
{
   double nv = NormalizeLots(v);
   if(MathAbs(nv - g_Lots) > 0.0000001)
   {
      g_Lots = nv;
      Print("🎚 Lotaje ajustado a: ", DoubleToString(g_Lots, 2), " (", _Symbol, ")");
   }
   else g_Lots = nv;
   SaveState();
   ExportStateToFile();
   UpdateInfoBar();
   RebuildActiveTab();
}

int CalcSplitCount(double totalLots)
{
   if(totalLots <= InpMaxLotsPerOrder) return 1;
   return (int)MathCeil(totalLots / InpMaxLotsPerOrder);
}

double CalcSplitLot(double totalLots, int partIndex, int totalParts)
{
   double maxLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double minLot  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double stepLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double capLot  = MathMin(InpMaxLotsPerOrder, maxLot);
   double full    = MathFloor(totalLots / capLot);
   double rem     = totalLots - full * capLot;
   double lot     = (partIndex < (int)full) ? capLot : ((rem > 0.0) ? rem : capLot);
   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(lot, minLot);
   return NormalizeDouble(lot, 2);
}

double CalcSL(double openPrice, int posType)
{
   int dg = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(posType==POSITION_TYPE_BUY||posType==ORDER_TYPE_BUY||
      posType==ORDER_TYPE_BUY_LIMIT||posType==ORDER_TYPE_BUY_STOP)
      return NormalizeDouble(openPrice - SL_Points*point, dg);
   return NormalizeDouble(openPrice + SL_Points*point, dg);
}

double CalcTP(double openPrice, int posType)
{
   int dg = (int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(posType==POSITION_TYPE_BUY||posType==ORDER_TYPE_BUY||
      posType==ORDER_TYPE_BUY_LIMIT||posType==ORDER_TYPE_BUY_STOP)
      return NormalizeDouble(openPrice + TP_Points*point, dg);
   return NormalizeDouble(openPrice - TP_Points*point, dg);
}

bool NeedsSLTP(double sl, double tp){ return (sl==0.0||tp==0.0); }

//+------------------------------------------------------------------+
//| RESTAURAR SL/TP (solo si faltan: nunca se mueve un SL ya puesto)|
//+------------------------------------------------------------------+
bool RestoreSLTP(ulong ticket, double sl, double tp)
{
   if(!PositionSelectByTicket(ticket)) return false;
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_SLTP; req.position=ticket;
   req.symbol=PositionGetString(POSITION_SYMBOL);
   req.sl=sl; req.tp=tp;
   if(!OrderSend(req,res)||res.retcode!=TRADE_RETCODE_DONE)
   { Print("ERROR RestoreSLTP t=",ticket," err=",GetLastError()); return false; }
   return true;
}

bool RestorePendingSLTP(ulong ticket, double sl, double tp)
{
   if(!OrderSelect(ticket)) return false;
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_MODIFY; req.order=ticket;
   req.price=OrderGetDouble(ORDER_PRICE_OPEN);
   req.sl=sl; req.tp=tp;
   if(!OrderSend(req,res)||res.retcode!=TRADE_RETCODE_DONE)
   { Print("ERROR RestorePendingSLTP t=",ticket," err=",GetLastError()); return false; }
   return true;
}

void EnforceSLTP()
{
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0||!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double curSL=PositionGetDouble(POSITION_SL);
      double curTP=PositionGetDouble(POSITION_TP);
      if(!NeedsSLTP(curSL,curTP)) continue;
      double openP=PositionGetDouble(POSITION_PRICE_OPEN);
      int pt=(int)PositionGetInteger(POSITION_TYPE);
      // Cierre fijo: SL y TP siempre los del asistente, sin trailing ni break-even
      RestoreSLTP(ticket,(curSL==0.0)?CalcSL(openP,pt):curSL,
                        (curTP==0.0)?CalcTP(openP,pt):curTP);
   }

   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0||!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      int otype=(int)OrderGetInteger(ORDER_TYPE);
      if(otype!=ORDER_TYPE_BUY_LIMIT&&otype!=ORDER_TYPE_SELL_LIMIT&&
         otype!=ORDER_TYPE_BUY_STOP&&otype!=ORDER_TYPE_SELL_STOP) continue;
      double curSL=OrderGetDouble(ORDER_SL);
      double curTP=OrderGetDouble(ORDER_TP);
      if(!NeedsSLTP(curSL,curTP)) continue;
      double openP=OrderGetDouble(ORDER_PRICE_OPEN);
      RestorePendingSLTP(ticket,(curSL==0.0)?CalcSL(openP,otype):curSL,
                         (curTP==0.0)?CalcTP(openP,otype):curTP);
   }
}

//+------------------------------------------------------------------+
//| SYNC TRADES                                                      |
//+------------------------------------------------------------------+
void SyncAllTrades()
{
   // Copia del estado previo para detectar posiciones que desaparecen (cerradas por TP/SL)
   TradeRecord prev[];
   int prevCount=g_TradeCount;
   ArrayResize(prev,prevCount);
   for(int i=0;i<prevCount;i++) prev[i]=g_Trades[i];

   g_TradeCount=0; ArrayResize(g_Trades,0);

   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0||!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      int idx=g_TradeCount; ArrayResize(g_Trades,idx+1);
      g_Trades[idx].ticket=ticket; g_Trades[idx].isPending=false;
      g_Trades[idx].orderType=(int)PositionGetInteger(POSITION_TYPE);
      g_Trades[idx].lots=PositionGetDouble(POSITION_VOLUME);
      g_Trades[idx].openPrice=PositionGetDouble(POSITION_PRICE_OPEN);
      g_Trades[idx].sl=PositionGetDouble(POSITION_SL);
      g_Trades[idx].tp=PositionGetDouble(POSITION_TP);
      g_Trades[idx].profit=PositionGetDouble(POSITION_PROFIT);
      g_Trades[idx].splitGroupId=0;
      for(int p2=0;p2<prevCount;p2++)
         if(prev[p2].ticket==ticket) { g_Trades[idx].splitGroupId=prev[p2].splitGroupId; break; }
      g_TradeCount++;
   }

   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0||!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      int otype=(int)OrderGetInteger(ORDER_TYPE);
      if(otype!=ORDER_TYPE_BUY_LIMIT&&otype!=ORDER_TYPE_SELL_LIMIT&&
         otype!=ORDER_TYPE_BUY_STOP&&otype!=ORDER_TYPE_SELL_STOP) continue;
      int idx=g_TradeCount; ArrayResize(g_Trades,idx+1);
      g_Trades[idx].ticket=ticket; g_Trades[idx].isPending=true;
      g_Trades[idx].orderType=otype;
      g_Trades[idx].lots=OrderGetDouble(ORDER_VOLUME_CURRENT);
      g_Trades[idx].openPrice=OrderGetDouble(ORDER_PRICE_OPEN);
      g_Trades[idx].sl=OrderGetDouble(ORDER_SL);
      g_Trades[idx].tp=OrderGetDouble(ORDER_TP);
      g_Trades[idx].profit=0.0; g_Trades[idx].splitGroupId=0;
      for(int p2=0;p2<prevCount;p2++)
         if(prev[p2].ticket==ticket) { g_Trades[idx].splitGroupId=prev[p2].splitGroupId; break; }
      g_TradeCount++;
   }

   // Posiciones que ya no existen -> cola de cierres (solo para loguear, no cambia nada mas)
   for(int i=0;i<prevCount;i++)
   {
      if(prev[i].isPending) continue;
      bool still=false;
      for(int k=0;k<g_TradeCount;k++)
         if(g_Trades[k].ticket==prev[i].ticket){still=true;break;}
      if(!still)
      {
         int qn=ArraySize(g_ClosedQueue);
         ArrayResize(g_ClosedQueue,qn+1);
         g_ClosedQueue[qn]=prev[i];
      }
   }

   if(g_ScrollOffset>=g_TradeCount&&g_ScrollOffset>0)
      g_ScrollOffset=MathMax(0,g_TradeCount-1);
}

int FindTrade(ulong ticket)
{
   for(int i=0;i<g_TradeCount;i++)
      if(g_Trades[i].ticket==ticket) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| HELPERS GRÁFICOS                                                 |
//+------------------------------------------------------------------+
void ObjRect(string n,int x,int y,int w,int h,color bg,color brd,int bw=1)
{
   ObjectDelete(0,n); ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w); ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg); ObjectSetInteger(0,n,OBJPROP_BORDER_COLOR,brd);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT); ObjectSetInteger(0,n,OBJPROP_WIDTH,bw);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER); ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_ZORDER,0);
}

void ObjLbl(string n,int x,int y,string txt,color clr,int fs=9,string font="Arial Bold",
            ENUM_ANCHOR_POINT anc=ANCHOR_LEFT_UPPER)
{
   ObjectDelete(0,n); ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,n,OBJPROP_TEXT,txt); ObjectSetInteger(0,n,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs); ObjectSetString(0,n,OBJPROP_FONT,font);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER); ObjectSetInteger(0,n,OBJPROP_ANCHOR,anc);
   ObjectSetInteger(0,n,OBJPROP_BACK,false); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_ZORDER,10);
}

void ObjBtn(string n,int x,int y,int w,int h,string txt,color bg,color fg,
            int fs=9,string font="Arial Bold")
{
   ObjectDelete(0,n); ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w); ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,txt); ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,fg); ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,font); ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BACK,false); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_ZORDER,20); ObjectSetInteger(0,n,OBJPROP_STATE,false);
}

void ObjEdit(string n,int x,int y,int w,int h,string txt,color bg,color fg,int fs=10)
{
   ObjectDelete(0,n); ObjectCreate(0,n,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w); ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,txt); ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,fg); ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_CENTER);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_BACK,false); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_ZORDER,30); ObjectSetInteger(0,n,OBJPROP_READONLY,false);
}

void ObjSep(string n,int x,int y,int w)
{ ObjRect(n,x,y,w,1,C'70,70,100',C'70,70,100',0); }

string GetTypeName(int otype,bool isPending)
{
   if(!isPending) return(otype==POSITION_TYPE_BUY)?"BUY":"SELL";
   switch(otype)
   { case ORDER_TYPE_BUY_LIMIT: return "BUY LMT"; case ORDER_TYPE_SELL_LIMIT: return "SELL LMT";
     case ORDER_TYPE_BUY_STOP: return "BUY STP"; case ORDER_TYPE_SELL_STOP: return "SELL STP";
     default: return "PENDING"; }
}

color GetTypeColor(int otype,bool isPending)
{
   if(!isPending) return(otype==POSITION_TYPE_BUY)?clrLimeGreen:clrTomato;
   return(otype==ORDER_TYPE_BUY_LIMIT||otype==ORDER_TYPE_BUY_STOP)?C'100,220,100':C'220,100,100';
}

//+------------------------------------------------------------------+
//| PANEL                                                            |
//+------------------------------------------------------------------+
void BuildStaticStructure()
{
   int x=PNL_X,y=PNL_Y,W=PNL_W;
   ObjRect(PFX+"BG",x,y,W,PNL_H,C'18,18,28',C'70,70,160',2);
   ObjRect(PFX+"TITLE_BG",x,y,W,30,C'8,8,42',C'70,70,200',1);
   ObjLbl(OBJ_TITLE,x+W/2,y+7,"  TP FIJO · SIN TRAILING  v5.0  ",
          clrGold,11,"Arial Bold",ANCHOR_CENTER);

   int cellW=W/4;
   ObjRect(PFX+"IB_BG",x,y+30,W,34,C'14,22,14',C'40,80,40',1);
   string ibHdr[4]={"LOTAJE","R:R","P&L","EQUIDAD"};
   string ibObj[4]={OBJ_INFOBAR_LOT,OBJ_INFOBAR_RR,OBJ_INFOBAR_PL,OBJ_INFOBAR_EQ};
   for(int c=0;c<4;c++)
   {
      int cx=x+c*cellW+1,cw=(c<3)?cellW-2:W-cellW*3-2;
      ObjRect(PFX+"IB_C"+IntegerToString(c),cx,y+31,cw,32,C'20,30,20',C'40,70,40',1);
      ObjLbl(PFX+"IB_H"+IntegerToString(c),cx+cw/2,y+33,ibHdr[c],clrSilver,6,"Arial",ANCHOR_CENTER);
      ObjLbl(ibObj[c],cx+cw/2,y+42,"---",clrWhite,10,"Arial Bold",ANCHOR_CENTER);
   }

   int tabW=W/N_TABS;
   for(int t=0;t<N_TABS;t++)
   {
      bool active=(t==ActiveTab);
      ObjBtn(PFX+"TAB"+IntegerToString(t),x+t*tabW,y+64,tabW,TAB_H,TAB_NAMES[t],
             active?C'40,40,80':C'22,22,40',active?clrGold:clrSilver,8,"Arial Bold");
      if(active)
         ObjRect(PFX+"TABU"+IntegerToString(t),x+t*tabW+2,y+64+TAB_H-3,tabW-4,3,clrGold,clrGold,0);
   }
   ObjRect(PFX+"CONTENT_BG",x,y+CONTENT_Y0,W,CONTENT_H,C'22,22,34',C'55,55,110',1);
}

void RefreshTabBar()
{
   int x=PNL_X,y=PNL_Y,W=PNL_W,tabW=W/N_TABS;
   for(int t=0;t<N_TABS;t++)
   {
      bool active=(t==ActiveTab);
      ObjectSetInteger(0,PFX+"TAB"+IntegerToString(t),OBJPROP_BGCOLOR,active?C'40,40,80':C'22,22,40');
      ObjectSetInteger(0,PFX+"TAB"+IntegerToString(t),OBJPROP_COLOR,active?clrGold:clrSilver);
      if(active) ObjRect(PFX+"TABU"+IntegerToString(t),x+t*tabW+2,y+64+TAB_H-3,tabW-4,3,clrGold,clrGold,0);
      else ObjectDelete(0,PFX+"TABU"+IntegerToString(t));
   }
}

void UpdateInfoBar()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double fPL=eq-bal;
   double rr=(SL_Points>0)?TP_Points/SL_Points:0;
   int parts=CalcSplitCount(g_Lots);
   string lotTxt=(parts>1)?StringFormat("%.2f x%d",g_Lots,parts):StringFormat("%.2f",g_Lots);
   ObjectSetString(0,OBJ_INFOBAR_LOT,OBJPROP_TEXT,lotTxt);
   ObjectSetString(0,OBJ_INFOBAR_RR,OBJPROP_TEXT,StringFormat("1:%.2f",rr));
   ObjectSetInteger(0,OBJ_INFOBAR_RR,OBJPROP_COLOR,clrMagenta);
   ObjectSetString(0,OBJ_INFOBAR_PL,OBJPROP_TEXT,StringFormat("%s%.2f",(fPL>=0)?"+":"",fPL));
   ObjectSetInteger(0,OBJ_INFOBAR_PL,OBJPROP_COLOR,(fPL>=0)?clrLimeGreen:clrTomato);
   ObjectSetString(0,OBJ_INFOBAR_EQ,OBJPROP_TEXT,StringFormat("%.2f",eq));
   ObjectSetInteger(0,OBJ_INFOBAR_EQ,OBJPROP_COLOR,(eq>=bal)?clrLimeGreen:clrTomato);
}

void DeleteContentObjects()
{
   string pfxList[4]={PFX_OP,PFX_ACC,PFX_POS,PFX_CFG};
   int total=ObjectsTotal(0,0,-1);
   for(int i=total-1;i>=0;i--)
   {
      string name=ObjectName(0,i,0,-1);
      for(int p=0;p<4;p++)
         if(StringFind(name,pfxList[p])==0){ObjectDelete(0,name);break;}
   }
   ObjectDelete(0,EDIT_PRICE_NAME);
   ObjectDelete(0,EDIT_LOT_NAME);
}

void DeletePanel()
{
   int total=ObjectsTotal(0,0,-1);
   for(int i=total-1;i>=0;i--)
   {
      string name=ObjectName(0,i,0,-1);
      if(StringFind(name,PFX)==0) ObjectDelete(0,name);
   }
   ObjectDelete(0,EDIT_PRICE_NAME);
   ObjectDelete(0,EDIT_LOT_NAME);
   ChartRedraw();
}

void RebuildActiveTab()
{
   DeleteContentObjects(); RefreshTabBar();
   switch(ActiveTab)
   { case TAB_OPERAR: BuildTabOperar(); break; case TAB_CUENTA: BuildTabCuenta(); break;
     case TAB_POSIC: BuildTabPosiciones(); break; case TAB_CONFIG: BuildTabConfig(); break; }
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| TABS                                                             |
//+------------------------------------------------------------------+
void BuildTabOperar()
{
   int x=PNL_X,W=PNL_W,y=PNL_Y+CONTENT_Y0+4;
   int cx=x+4,cw=W-8;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);

   // ── SL / TP / R:R ────────────────────────────
   ObjRect(PFX_OP+"SLTP_BG",cx,y,cw,38,C'28,28,44',C'55,55,90',1);
   double rr=(SL_Points>0)?TP_Points/SL_Points:0;
   ObjLbl(PFX_OP+"H_SL",cx+4,y+3,"SL:",clrTomato,7,"Arial");
   ObjLbl(PFX_OP+"V_SL",cx+22,y+3,StringFormat("%.0f pts",SL_Points),clrTomato,7,"Arial Bold");
   ObjLbl(PFX_OP+"H_TP",cx+95,y+3,"TP:",clrDodgerBlue,7,"Arial");
   ObjLbl(PFX_OP+"V_TP",cx+113,y+3,StringFormat("%.0f pts",TP_Points),clrDodgerBlue,7,"Arial Bold");
   ObjLbl(PFX_OP+"H_RR",cx+190,y+3,"R:R:",clrMagenta,7,"Arial");
   ObjLbl(PFX_OP+"V_RR",cx+212,y+3,StringFormat("1:%.2f",rr),clrMagenta,7,"Arial Bold");

   double mid=MidPriceNorm();
   int parts=CalcSplitCount(g_Lots);
   ObjLbl(PFX_OP+"V_MID",cx+4,y+14,StringFormat("Mid: %.*f  |  Lot: %.2f",dg,mid,g_Lots),clrSilver,8,"Arial");
   if(parts>1) ObjLbl(PFX_OP+"SPLIT_INFO",cx+4,y+25,
      StringFormat("⚡ SPLIT: %d órdenes",parts),clrYellow,7,"Arial Bold");
   else ObjLbl(PFX_OP+"CLOSEMODE",cx+4,y+25,"✔ cierre solo por TP / SL · sin trailing",
      C'120,215,120',7,"Arial");
   y+=42;

   // ── LOTAJE ÚNICO EDITABLE ────────────────────
   ObjLbl(PFX_OP+"LOT_H",cx+2,y,"LOTAJE POR PAR  (EDITABLE)",clrSilver,7,"Arial");
   ObjLbl(PFX_OP+"LOT_MIN",cx+cw-2,y,StringFormat("mín %.2f / paso %.2f",
      SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN),SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP)),
      C'130,130,160',6,"Arial",ANCHOR_RIGHT_UPPER);
   y+=13;
   ObjEdit(EDIT_LOT_NAME,cx,y,92,26,DoubleToString(g_Lots,2),C'30,30,48',clrWhite,11);
   int lbw=51,bx=cx+96;
   string lb[4]={"-0.01","+0.01","/ 2","x 2"};
   color  lbc[4]={C'95,45,45',C'40,90,40',C'70,70,95',C'70,70,95'};
   for(int i=0;i<4;i++)
      ObjBtn(PFX_OP+"LOTB"+IntegerToString(i),bx+i*(lbw+4),y,lbw,26,lb[i],lbc[i],clrWhite,8,"Arial Bold");
   y+=30;

   // ── GANANCIA / PÉRDIDA CON EL SL Y TP DEL ASISTENTE ──
   ObjSep(PFX_OP+"SEP1",cx,y,cw); y+=6;
   double riskUSD=CalcRiskDollars(g_Lots);
   double profitUSD=CalcProfitDollars(g_Lots);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   string cur=AcctCur();
   double pctBal=(balance>0)?(riskUSD/balance)*100.0:0.0;
   double pctWin=(balance>0)?(profitUSD/balance)*100.0:0.0;
   color riskClr=(pctBal<=1.0)?clrLimeGreen:(pctBal<=2.0)?clrYellow:(pctBal<=5.0)?clrOrange:clrTomato;

   int halfw=(cw-6)/2;
   ObjRect(PFX_OP+"LOSS_BG",cx,y,halfw,54,C'36,18,18',C'130,50,50',1);
   ObjLbl(PFX_OP+"LOSS_H",cx+6,y+4,"PERDERÍA SI TOCA SL",clrTomato,7,"Arial");
   ObjLbl(PFX_OP+"LOSS_V",cx+6,y+17,StringFormat("-%.2f %s",riskUSD,cur),clrTomato,13,"Arial Bold");
   ObjLbl(PFX_OP+"LOSS_P",cx+6,y+38,StringFormat("%.2f%% del balance",pctBal),riskClr,7,"Arial");

   ObjRect(PFX_OP+"WIN_BG",cx+halfw+6,y,halfw,54,C'18,34,18',C'50,130,50',1);
   ObjLbl(PFX_OP+"WIN_H",cx+halfw+12,y+4,"GANARÍA SI TOCA TP",clrLimeGreen,7,"Arial");
   ObjLbl(PFX_OP+"WIN_V",cx+halfw+12,y+17,StringFormat("+%.2f %s",profitUSD,cur),clrLimeGreen,13,"Arial Bold");
   ObjLbl(PFX_OP+"WIN_P",cx+halfw+12,y+38,StringFormat("%.2f%% del balance",pctWin),clrLimeGreen,7,"Arial");
   y+=58;

   double pPerLot=NormalizeDouble(ValuePerPoint()*SL_Points,2);
   ObjLbl(PFX_OP+"PRICES",cx+2,y,
      StringFormat("Mid → SL %.*f | TP %.*f  ·  %.2f %s/lote a SL  ·  %.2f %s/lote a TP",
                   dg,NormalizeDouble(mid-SL_Points*point,dg),dg,NormalizeDouble(mid+TP_Points*point,dg),
                   pPerLot,cur,NormalizeDouble(ValuePerPoint()*TP_Points,2),cur),C'150,150,190',7,"Arial");
   y+=16;

   // ── PRECIO LÍMITE ────────────────────────────
   ObjSep(PFX_OP+"SEP2",cx,y,cw); y+=5;
   ObjLbl(PFX_OP+"PH",cx+2,y,"PRECIO LÍMITE",clrSilver,7,"Arial");
   y+=13;
   ObjEdit(EDIT_PRICE_NAME,cx,y,cw,26,
      (g_LimitPrice>0)?DoubleToString(g_LimitPrice,dg):"0",C'30,30,48',clrWhite,10);
   y+=30;

   int tw=(cw-8)/3;
   ObjBtn(PFX_OP+"ASK",cx,y,tw,20,"= ASK",C'0,70,110',clrWhite,8,"Arial");
   ObjBtn(PFX_OP+"BID",cx+tw+4,y,tw,20,"= BID",C'110,55,0',clrWhite,8,"Arial");
   ObjBtn(PFX_OP+"RST",cx+2*(tw+4),y,tw,20,"RESET",C'60,60,60',clrWhite,8,"Arial");
   y+=24;

   // ── BOTONERAS DE OPERACIÓN ───────────────────
   ObjSep(PFX_OP+"SEP3",cx,y,cw); y+=5;
   int obw=(cw-4)/2,obh=38;
   ObjBtn(PFX_OP+"BUY",cx,y,obw,obh,"▲  BUY",C'0,155,0',clrWhite,12);
   ObjBtn(PFX_OP+"SELL",cx+obw+4,y,obw,obh,"▼  SELL",C'205,0,0',clrWhite,12);
   y+=obh+4;
   ObjBtn(PFX_OP+"BUYLMT",cx,y,obw,32,"BUY LIMIT",C'0,105,75',clrWhite,9);
   ObjBtn(PFX_OP+"SELLLMT",cx+obw+4,y,obw,32,"SELL LIMIT",C'160,50,0',clrWhite,9);
   y+=36;
   ObjSep(PFX_OP+"SEP4",cx,y,cw); y+=5;
   ObjBtn(PFX_OP+"CLOSEALL",cx,y,cw,28,"✖  CERRAR TODAS LAS POSICIONES",C'95,0,95',clrWhite,9);
}

void BuildCuentaRow(string pfx,int cx,int ry,int cw,int rh,
                    string hdr,string val,color bgC,color brdC,color valC)
{
   ObjRect(pfx+"BG",cx,ry,cw,rh,bgC,brdC,1);
   ObjLbl(pfx+"H",cx+6,ry+3,hdr,clrSilver,7,"Arial");
   ObjLbl(pfx+"V",cx+cw-6,ry+3,val,valC,11,"Arial Bold",ANCHOR_RIGHT_UPPER);
}

void BuildTabCuenta()
{
   int x=PNL_X,W=PNL_W,y=PNL_Y+CONTENT_Y0+6;
   int cx=x+6,cw=W-12;
   string cur=AccountInfoString(ACCOUNT_CURRENCY);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double margin=AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMrg=AccountInfoDouble(ACCOUNT_FREEMARGIN);
   double mrgLv=(margin>0)?(equity/margin)*100.0:0.0;
   double floatPL=equity-balance;

   BuildCuentaRow(PFX_ACC+"BAL",cx,y,cw,34,"BALANCE",StringFormat("%.2f %s",balance,cur),C'20,25,40',C'45,55,90',clrWhite); y+=38;
   BuildCuentaRow(PFX_ACC+"EQ",cx,y,cw,34,"EQUIDAD",StringFormat("%.2f %s",equity,cur),C'20,25,40',C'45,55,90',(equity>=balance)?clrLimeGreen:clrTomato); y+=38;
   BuildCuentaRow(PFX_ACC+"PL",cx,y,cw,34,"P&L FLOTANTE",StringFormat("%s%.2f %s",(floatPL>=0)?"+":"",floatPL,cur),C'20,25,40',C'45,55,90',(floatPL>=0)?clrLimeGreen:clrTomato); y+=38;
   BuildCuentaRow(PFX_ACC+"MRG",cx,y,cw,34,"MARGEN",StringFormat("%.2f %s",margin,cur),C'20,25,40',C'45,55,90',clrOrange); y+=38;
   BuildCuentaRow(PFX_ACC+"FM",cx,y,cw,34,"LIBRE",StringFormat("%.2f %s",freeMrg,cur),C'20,25,40',C'45,55,90',(freeMrg<balance*0.20)?clrTomato:clrLimeGreen); y+=38;

   string mTxt; color mC;
   if(margin<=0) {mTxt="N/A";mC=clrSilver;}
   else if(mrgLv>=200) {mTxt=StringFormat("%.0f%%",mrgLv);mC=clrLimeGreen;}
   else if(mrgLv>=120) {mTxt=StringFormat("%.0f%%",mrgLv);mC=clrYellow;}
   else {mTxt=StringFormat("%.0f%%",mrgLv);mC=clrTomato;}
   BuildCuentaRow(PFX_ACC+"MPC",cx,y,cw,34,"NIVEL MARGEN",mTxt,C'20,25,40',C'45,55,90',mC); y+=42;

   // Proyección de la posición/pedido actual con el lotaje del asistente
   double rl=CalcRiskDollars(g_Lots), gl=CalcProfitDollars(g_Lots);
   BuildCuentaRow(PFX_ACC+"EXP",cx,y,cw,34,"SI TOCA TP (1 op.)",StringFormat("+%.2f %s",gl,cur),C'18,32,18',C'45,90,45',clrLimeGreen); y+=38;
   BuildCuentaRow(PFX_ACC+"EXPL",cx,y,cw,34,"SI TOCA SL (1 op.)",StringFormat("-%.2f %s",rl,cur),C'32,18,18',C'90,45,45',clrTomato); y+=38;

   long accNum=(long)AccountInfoInteger(ACCOUNT_LOGIN);
   string accType=(AccountInfoInteger(ACCOUNT_TRADE_MODE)==ACCOUNT_TRADE_MODE_DEMO)?"DEMO":"REAL";
   ObjLbl(PFX_ACC+"BROKER",cx,y,StringFormat("Broker: %s",AccountInfoString(ACCOUNT_COMPANY)),clrSilver,7,"Arial"); y+=13;
   ObjLbl(PFX_ACC+"ACCNUM",cx,y,StringFormat("Cuenta #%d [%s]",(int)accNum,accType),(accType=="DEMO")?clrYellow:clrLimeGreen,7,"Arial Bold");
}

void BuildTabPosiciones()
{
   int x=PNL_X,W=PNL_W,y=PNL_Y+CONTENT_Y0+4;
   int cx=x+4,cw=W-8;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   string cur=AcctCur();

   int nPos=0,nPend=0; double totalPL=0, totGain=0, totLoss=0;
   for(int i=0;i<g_TradeCount;i++)
   {
      if(g_Trades[i].isPending) nPend++;
      else { nPos++; totalPL+=g_Trades[i].profit;
             totGain+=TradeGainIfTP(g_Trades[i]);
             totLoss+=TradeLossIfSL(g_Trades[i]); }
   }

   ObjRect(PFX_POS+"HDR",cx,y,cw,40,C'15,28,35',C'35,70,100',1);
   ObjLbl(PFX_POS+"HDR1",cx+4,y+3,StringFormat("%d abiertas | %d pendientes",nPos,nPend),clrSilver,8,"Arial Bold");
   ObjLbl(PFX_POS+"HDRPL",cx+cw-4,y+3,StringFormat("P&L: %s%.2f",(totalPL>=0)?"+":"",totalPL),(totalPL>=0)?clrLimeGreen:clrTomato,8,"Arial Bold",ANCHOR_RIGHT_UPPER);
   ObjLbl(PFX_POS+"HDRTP",cx+4,y+22,StringFormat("Si todas tocan TP: +%.2f %s   |   si todas tocan SL: -%.2f %s",totGain,cur,totLoss,cur),C'170,170,200',7,"Arial");
   y+=44;

   if(g_TradeCount==0)
   {
      ObjRect(PFX_POS+"EMPTY",cx,y,cw,50,C'22,22,32',C'50,50,80',1);
      ObjLbl(PFX_POS+"EMPTYTXT",cx+cw/2,y+18,"No hay operaciones en "+_Symbol,clrSilver,9,"Arial",ANCHOR_CENTER);
      ObjLbl(PFX_POS+"EMPTYTXT2",cx+cw/2,y+33,"Cierre fijo por TP · sin trailing stop",C'120,215,120',7,"Arial",ANCHOR_CENTER);
      return;
   }

   int rowH=44,maxVisible=6;
   int visible=MathMin(g_TradeCount-g_ScrollOffset,maxVisible);
   for(int v=0;v<visible;v++)
   {
      int k=v+g_ScrollOffset; if(k>=g_TradeCount) break;
      TradeRecord tr=g_Trades[k];
      string rid=IntegerToString(k);
      color rowBg,rowBrd;
      if(tr.isPending) {rowBg=C'25,25,18';rowBrd=C'80,80,30';}
      else if(tr.orderType==0) {rowBg=C'18,30,18';rowBrd=C'35,90,35';}
      else {rowBg=C'30,18,18';rowBrd=C'90,35,35';}
      ObjRect(PFX_POS+"ROW"+rid,cx,y,cw,rowH-2,rowBg,rowBrd,1);
      ObjLbl(PFX_POS+"R1"+rid,cx+6,y+2,
         StringFormat("%s #%d  %.2f lots",GetTypeName(tr.orderType,tr.isPending),(int)tr.ticket,tr.lots),
         GetTypeColor(tr.orderType,tr.isPending),8,"Arial Bold");
      ObjLbl(PFX_POS+"RR"+rid,cx+cw-6,y+2,
         StringFormat("TP +%.2f | SL -%.2f",TradeGainIfTP(tr),TradeLossIfSL(tr)),C'170,170,200',7,"Arial",ANCHOR_RIGHT_UPPER);
      ObjLbl(PFX_POS+"R2"+rid,cx+6,y+15,
         StringFormat("P.Ap: %.*f  SL:%.*f  TP:%.*f",dg,tr.openPrice,dg,tr.sl,dg,tr.tp),clrSilver,6,"Arial");
      if(!tr.isPending)
         ObjLbl(PFX_POS+"R3"+rid,cx+6,y+27,StringFormat("P&L: %s%.2f %s",(tr.profit>=0)?"+":"",tr.profit,cur),
            (tr.profit>=0)?clrLimeGreen:clrTomato,9,"Arial Bold");
      else
         ObjLbl(PFX_POS+"R3"+rid,cx+6,y+27,"Esperando ejecución...",C'160,150,80',8,"Arial");
      y+=rowH+2;
   }

   if(g_TradeCount>maxVisible)
   {
      int hw=(cw-4)/2;
      ObjBtn(PFX_POS+"SCRUP",cx,y,hw,20,"▲ Anterior",C'38,38,58',clrWhite,8,"Arial");
      ObjBtn(PFX_POS+"SCRDN",cx+hw+4,y,hw,20,"▼ Siguiente",C'38,38,58',clrWhite,8,"Arial");
   }
}

void BuildTabConfig()
{
   int x=PNL_X,W=PNL_W,y=PNL_Y+CONTENT_Y0+6;
   int cx=x+6,cw=W-12;
   ObjLbl(PFX_CFG+"T1",cx,y,"PARÁMETROS ACTIVOS",clrGold,9,"Arial Bold"); y+=18;
   ObjSep(PFX_CFG+"S1",cx,y,cw); y+=8;

   string cur=AcctCur();
   double riskUSD=CalcRiskDollars(g_Lots);
   double profitUSD=CalcProfitDollars(g_Lots);
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double pctBal=(balance>0)?(riskUSD/balance)*100.0:0.0;

   string cfgL[12],cfgV[12]; color cfgC[12];
   cfgL[0]="Simbolo"; cfgV[0]=_Symbol; cfgC[0]=clrWhite;
   cfgL[1]="Magic"; cfgV[1]=IntegerToString(InpMagicNumber); cfgC[1]=clrYellow;
   cfgL[2]="Stop Loss"; cfgV[2]=StringFormat("%.0f pts",SL_Points); cfgC[2]=clrTomato;
   cfgL[3]="Take Profit"; cfgV[3]=StringFormat("%.0f pts",TP_Points); cfgC[3]=clrDodgerBlue;
   cfgL[4]="R:R"; cfgV[4]=StringFormat("1:%.2f",TP_Points/MathMax(SL_Points,1)); cfgC[4]=clrMagenta;
   cfgL[5]="Lotaje"; cfgV[5]=StringFormat("%.2f (fijo)",g_Lots); cfgC[5]=clrGold;
   cfgL[6]="Pierde con SL"; cfgV[6]=StringFormat("-%.2f %s (%.2f%%)",riskUSD,cur,pctBal); cfgC[6]=clrTomato;
   cfgL[7]="Gana con TP"; cfgV[7]=StringFormat("+%.2f %s",profitUSD,cur); cfgC[7]=clrLimeGreen;
   cfgL[8]="Cierre"; cfgV[8]="TP FIJO · SIN TRAILING"; cfgC[8]=clrGold;
   cfgL[9]="Archivo estado"; cfgV[9]=g_StateFileName; cfgC[9]=clrSilver;
   cfgL[10]="Login"; cfgV[10]=IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)); cfgC[10]=clrYellow;
   cfgL[11]="Broker"; cfgV[11]=AccountInfoString(ACCOUNT_COMPANY); cfgC[11]=clrSilver;

   for(int i=0;i<12;i++)
   {
      color bg=(i%2==0)?C'24,24,36':C'20,20,30';
      ObjRect(PFX_CFG+"ROW"+IntegerToString(i),cx,y,cw,20,bg,bg,0);
      ObjLbl(PFX_CFG+"LH"+IntegerToString(i),cx+4,y+4,cfgL[i],clrSilver,8,"Arial");
      ObjLbl(PFX_CFG+"LV"+IntegerToString(i),cx+cw-4,y+4,cfgV[i],cfgC[i],8,"Arial Bold",ANCHOR_RIGHT_UPPER);
      y+=20;
   }

   ObjSep(PFX_CFG+"S2",cx,y,cw); y+=6;
   ObjBtn(PFX_CFG+"SAVESTATE",cx,y,cw,24,"💾 Guardar estado",C'30,80,30',clrWhite,8,"Arial Bold");
   y+=30;
   ObjRect(PFX_CFG+"NOTE_BG",cx,y,cw,30,C'24,32,24',C'50,100,50',1);
   ObjLbl(PFX_CFG+"NOTE1",cx+6,y+4,"El SL NUNCA se mueve: nada de trailing ni break-even.",clrLimeGreen,7,"Arial");
   ObjLbl(PFX_CFG+"NOTE2",cx+6,y+16,"La operación cierra al tocar TP o SL (o con CERRAR TODAS).",clrSilver,7,"Arial");
}

//+------------------------------------------------------------------+
//| LÍNEA LÍMITE                                                    |
//+------------------------------------------------------------------+
void DrawRefLine(string name,double price,string label,color clr,ENUM_LINE_STYLE style,int width)
{
   string lname=name+"_L",tname=name+"_T";
   if(ObjectFind(0,lname)<0)
   { ObjectCreate(0,lname,OBJ_HLINE,0,0,price);
     ObjectSetInteger(0,lname,OBJPROP_COLOR,clr); ObjectSetInteger(0,lname,OBJPROP_WIDTH,width);
     ObjectSetInteger(0,lname,OBJPROP_STYLE,style); ObjectSetInteger(0,lname,OBJPROP_BACK,true);
     ObjectSetInteger(0,lname,OBJPROP_SELECTABLE,false); }
   else ObjectSetDouble(0,lname,OBJPROP_PRICE,price);
   if(ObjectFind(0,tname)<0)
   { ObjectCreate(0,tname,OBJ_TEXT,0,iTime(_Symbol,PERIOD_CURRENT,0),price);
     ObjectSetInteger(0,tname,OBJPROP_COLOR,clr); ObjectSetInteger(0,tname,OBJPROP_FONTSIZE,8);
     ObjectSetString(0,tname,OBJPROP_FONT,"Arial"); ObjectSetInteger(0,tname,OBJPROP_ANCHOR,ANCHOR_LEFT);
     ObjectSetInteger(0,tname,OBJPROP_BACK,false); ObjectSetInteger(0,tname,OBJPROP_SELECTABLE,false); }
   else ObjectMove(0,tname,0,iTime(_Symbol,PERIOD_CURRENT,0),price);
   ObjectSetString(0,tname,OBJPROP_TEXT,label);
}

void UpdateLimitLine()
{
   if(g_LimitPrice<=0.0){RemoveLimitLine();return;}
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(ObjectFind(0,LINE_LIMIT_NAME)<0)
   { ObjectCreate(0,LINE_LIMIT_NAME,OBJ_HLINE,0,0,g_LimitPrice);
     ObjectSetInteger(0,LINE_LIMIT_NAME,OBJPROP_COLOR,clrGold);
     ObjectSetInteger(0,LINE_LIMIT_NAME,OBJPROP_WIDTH,2);
     ObjectSetInteger(0,LINE_LIMIT_NAME,OBJPROP_STYLE,STYLE_DASH);
     ObjectSetInteger(0,LINE_LIMIT_NAME,OBJPROP_BACK,false);
     ObjectSetInteger(0,LINE_LIMIT_NAME,OBJPROP_SELECTABLE,true); }
   else ObjectSetDouble(0,LINE_LIMIT_NAME,OBJPROP_PRICE,g_LimitPrice);
   if(ObjectFind(0,LINE_LIMIT_LABEL)<0)
   { ObjectCreate(0,LINE_LIMIT_LABEL,OBJ_TEXT,0,iTime(_Symbol,PERIOD_CURRENT,0),g_LimitPrice);
     ObjectSetInteger(0,LINE_LIMIT_LABEL,OBJPROP_COLOR,clrGold);
     ObjectSetInteger(0,LINE_LIMIT_LABEL,OBJPROP_FONTSIZE,9);
     ObjectSetString(0,LINE_LIMIT_LABEL,OBJPROP_FONT,"Arial Bold");
     ObjectSetInteger(0,LINE_LIMIT_LABEL,OBJPROP_ANCHOR,ANCHOR_LEFT); }
   else ObjectMove(0,LINE_LIMIT_LABEL,0,iTime(_Symbol,PERIOD_CURRENT,0),g_LimitPrice);
   ObjectSetString(0,LINE_LIMIT_LABEL,OBJPROP_TEXT,
      StringFormat("  LIMIT: %s",DoubleToString(g_LimitPrice,dg)));
   // Líneas de SL y TP del asistente ancladas al precio límite
   double sl_buy=NormalizeDouble(g_LimitPrice-SL_Points*point,dg);
   double tp_buy=NormalizeDouble(g_LimitPrice+TP_Points*point,dg);
   DrawRefLine(LINE_LIMIT_SL,sl_buy,"  SL: "+DoubleToString(sl_buy,dg),clrTomato,STYLE_DOT,1);
   DrawRefLine(LINE_LIMIT_TP,tp_buy,"  TP: "+DoubleToString(tp_buy,dg),clrDodgerBlue,STYLE_DOT,1);
   ChartRedraw();
}

void RemoveLimitLine()
{
   ObjectDelete(0,LINE_LIMIT_NAME); ObjectDelete(0,LINE_LIMIT_LABEL);
   ObjectDelete(0,LINE_LIMIT_SL+"_L"); ObjectDelete(0,LINE_LIMIT_SL+"_T");
   ObjectDelete(0,LINE_LIMIT_TP+"_L"); ObjectDelete(0,LINE_LIMIT_TP+"_T");
   ChartRedraw();
}

double ReadEditPrice()
{
   string t=ObjectGetString(0,EDIT_PRICE_NAME,OBJPROP_TEXT);
   StringTrimLeft(t); StringTrimRight(t);
   return StringToDouble(t);
}

double ReadEditLot()
{
   string t=ObjectGetString(0,EDIT_LOT_NAME,OBJPROP_TEXT);
   StringTrimLeft(t); StringTrimRight(t);
   return StringToDouble(t);
}

void SyncLimitLinePrice()
{
   if(ObjectFind(0,LINE_LIMIT_NAME)<0) return;
   double linePrice=ObjectGetDouble(0,LINE_LIMIT_NAME,OBJPROP_PRICE);
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   linePrice=NormalizeDouble(linePrice,dg);
   if(MathAbs(linePrice-g_LimitPrice)>SymbolInfoDouble(_Symbol,SYMBOL_POINT)*0.5&&linePrice>0)
   {
      g_LimitPrice=linePrice;
      if(ObjectFind(0,EDIT_PRICE_NAME)>=0)
         ObjectSetString(0,EDIT_PRICE_NAME,OBJPROP_TEXT,DoubleToString(g_LimitPrice,dg));
      UpdateLimitLine();
      GlobalVariableSet(GV_LIMIT_PRICE,g_LimitPrice);
   }
}

//+------------------------------------------------------------------+
//| CIERRES (solo informativo: no hay gestion de SL, ni trailing)   |
//+------------------------------------------------------------------+
void FlushClosedQueue()
{
   int n=ArraySize(g_ClosedQueue);
   if(n<=0) return;
   for(int i=0;i<n;i++) LogClosedTrade(g_ClosedQueue[i]);
   ArrayResize(g_ClosedQueue,0);
}

void LogClosedTrade(const TradeRecord &rec)
{
   HistorySelect(0,TimeCurrent());
   double cp=0; bool found=false;
   for(int d=HistoryDealsTotal()-1;d>=0;d--)
   {
      ulong dt=HistoryDealGetTicket(d); if(dt==0) continue;
      if(HistoryDealGetInteger(dt,DEAL_POSITION_ID)!=(long)rec.ticket) continue;
      if(HistoryDealGetInteger(dt,DEAL_ENTRY)!=DEAL_ENTRY_OUT) continue;
      cp=HistoryDealGetDouble(dt,DEAL_PROFIT); found=true; break;
   }
   if(!found) return;
   Print(StringFormat("🔚 #%d %s %.2f lots | P&L: %s%.2f %s | %s",(int)rec.ticket,_Symbol,rec.lots,
                      (cp>=0)?"+":"",cp,AcctCur(),
                      (cp>0)?"✅ cerró en positivo (TP)":(cp<0?"⛔ cerró en negativo (SL)":"➖ neutra")));
}

//+------------------------------------------------------------------+
//| TRADING                                                         |
//+------------------------------------------------------------------+
bool _SendSingleMarket(ENUM_ORDER_TYPE ot,double lots,double sl,double tp,ulong groupId)
{
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_DEAL; req.symbol=_Symbol; req.volume=lots;
   req.type=ot; req.price=(ot==ORDER_TYPE_BUY)?SymbolInfoDouble(_Symbol,SYMBOL_ASK):SymbolInfoDouble(_Symbol,SYMBOL_BID);
   req.sl=sl; req.tp=tp; req.deviation=20; req.magic=InpMagicNumber;
   req.type_filling=ORDER_FILLING_IOC;
   req.comment=StringFormat("%s_TPF",InpComment);
   if(!OrderSend(req,res)||res.retcode!=TRADE_RETCODE_DONE) return false;
   return true;
}

bool _SendSingleLimit(ENUM_ORDER_TYPE ot,double lots,double price,double sl,double tp,ulong groupId)
{
   MqlTradeRequest req={}; MqlTradeResult res={};
   req.action=TRADE_ACTION_PENDING; req.symbol=_Symbol; req.volume=lots;
   req.type=ot; req.price=price; req.sl=sl; req.tp=tp; req.magic=InpMagicNumber;
   req.comment=StringFormat("%s_LMT",InpComment);
   if(!OrderSend(req,res)||res.retcode!=TRADE_RETCODE_DONE) return false;
   return true;
}

bool SendMarketOrder(ENUM_ORDER_TYPE ot,double totalLots)
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double mid=(ask+bid)/2.0;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double sl=(ot==ORDER_TYPE_BUY)?NormalizeDouble(mid-SL_Points*point,dg):NormalizeDouble(mid+SL_Points*point,dg);
   double tp=(ot==ORDER_TYPE_BUY)?NormalizeDouble(mid+TP_Points*point,dg):NormalizeDouble(mid-TP_Points*point,dg);
   int parts=CalcSplitCount(totalLots);
   ulong groupId=(ulong)TimeCurrent();
   int sent=0;
   for(int i=0;i<parts;i++)
   {
      double partLot=CalcSplitLot(totalLots,i,parts); if(partLot<=0) continue;
      if(i>0) Sleep(InpSplitDelayMs);
      if(_SendSingleMarket(ot,partLot,sl,tp,groupId)) sent++;
   }
   if(sent>0) Print("📤 ",(ot==ORDER_TYPE_BUY)?"BUY":"SELL"," ",DoubleToString(totalLots,2),
                    " lots | SL ",DoubleToString(sl,dg)," | TP ",DoubleToString(tp,dg),
                    " | ",(ot==ORDER_TYPE_BUY)?"+"+DoubleToString(CalcProfitDollars(totalLots),2):"-"+DoubleToString(CalcRiskDollars(totalLots),2)," ",AcctCur());
   return (sent>0);
}

bool SendLimitOrder(ENUM_ORDER_TYPE ot,double totalLots,double lp)
{
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK),bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(lp<=0) lp=NormalizeDouble((ask+bid)/2.0,dg);
   lp=NormalizeDouble(lp,dg);
   double sl=(ot==ORDER_TYPE_BUY_LIMIT||ot==ORDER_TYPE_BUY_STOP)?NormalizeDouble(lp-SL_Points*point,dg):NormalizeDouble(lp+SL_Points*point,dg);
   double tp=(ot==ORDER_TYPE_BUY_LIMIT||ot==ORDER_TYPE_BUY_STOP)?NormalizeDouble(lp+TP_Points*point,dg):NormalizeDouble(lp-TP_Points*point,dg);
   int parts=CalcSplitCount(totalLots);
   ulong groupId=(ulong)TimeCurrent();
   int sent=0;
   for(int i=0;i<parts;i++)
   {
      double partLot=CalcSplitLot(totalLots,i,parts); if(partLot<=0) continue;
      if(i>0) Sleep(InpSplitDelayMs);
      if(_SendSingleLimit(ot,partLot,lp,sl,tp,groupId)) sent++;
   }
   if(sent>0) Print("📤 ",(ot==ORDER_TYPE_BUY_LIMIT)?"BUY LIMIT":"SELL LIMIT"," ",DoubleToString(totalLots,2),
                    " lots @ ",DoubleToString(lp,dg)," | SL ",DoubleToString(sl,dg)," | TP ",DoubleToString(tp,dg));
   return (sent>0);
}

void CloseAllPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      string sym=PositionGetString(POSITION_SYMBOL);
      double vol=PositionGetDouble(POSITION_VOLUME);
      long pt=PositionGetInteger(POSITION_TYPE);
      MqlTradeRequest req={}; MqlTradeResult res={};
      req.action=TRADE_ACTION_DEAL; req.position=t; req.symbol=sym;
      req.volume=vol; req.deviation=20; req.magic=InpMagicNumber;
      req.comment="CLOSE_ALL"; req.type_filling=ORDER_FILLING_IOC;
      if(pt==POSITION_TYPE_BUY){req.type=ORDER_TYPE_SELL;req.price=SymbolInfoDouble(sym,SYMBOL_BID);}
      else {req.type=ORDER_TYPE_BUY;req.price=SymbolInfoDouble(sym,SYMBOL_ASK);}
      OrderSend(req,res);
   }
}

//+------------------------------------------------------------------+
//| OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit()
{
   SL_Points=InpSL_Points;
   TP_Points=InpTP_Points;
   PNL_X=InpPanelX; PNL_Y=InpPanelY;
   g_TradeCount=0; g_ScrollOffset=0;
   ArrayResize(g_Trades,0);
   ArrayResize(g_ClosedQueue,0);

   TAB_NAMES[0]="OPERAR"; TAB_NAMES[1]="CUENTA";
   TAB_NAMES[2]="POSIC."; TAB_NAMES[3]="CONFIG";

   InitGlobalVarKeys();
   InitSharedFileNames();
   LoadState();
   SyncAllTrades();
   BuildStaticStructure();
   RebuildActiveTab();
   UpdateInfoBar();

   if(g_LimitPrice > 0.0) UpdateLimitLine();

   // Exportar estado inicial
   ExportStateToFile();

   Print("EA v5.00 TP FIJO (sin trailing) | Lotaje ", DoubleToString(g_Lots,2),
         " | SL ", DoubleToString(SL_Points,0), " pts | TP ", DoubleToString(TP_Points,0),
         " pts | ", _Symbol, " | Magic: ", IntegerToString(InpMagicNumber),
         " | Login: ", IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   SaveState();
   ExportStateToFile();
   DeletePanel();
   RemoveLimitLine();
}

//+------------------------------------------------------------------+
//| OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick()
{
   // ── Leer comandos del Dashboard ──
   ReadCommandsFromFile();

   // ── Lógica del asistente ──
   int prevCount=g_TradeCount;
   SyncAllTrades();
   EnforceSLTP();            // asegura SL/TP, NUNCA los mueve (sin trailing)
   FlushClosedQueue();       // log de cada cierre (por TP o por SL)
   UpdateInfoBar();
   SyncLimitLinePrice();

   g_SaveCounter++;
   if(g_SaveCounter >= 300)
   { SaveState(); g_SaveCounter = 0; }

   // ── Exportar estado cada 50 ticks (~cada segundo) ──
   g_ExportCounter++;
   if(g_ExportCounter >= 50)
   { ExportStateToFile(); g_ExportCounter = 0; }

   if(g_TradeCount!=prevCount) RebuildActiveTab();
   else if(ActiveTab==TAB_CUENTA||ActiveTab==TAB_POSIC)
   {
      DeleteContentObjects();
      if(ActiveTab==TAB_CUENTA) BuildTabCuenta();
      if(ActiveTab==TAB_POSIC) BuildTabPosiciones();
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| OnChartEvent                                                    |
//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,
                  const double &dparam,const string &sparam)
{
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   // ── Edición del precio límite ──
   if(id==CHARTEVENT_OBJECT_ENDEDIT&&sparam==EDIT_PRICE_NAME)
   { double val=ReadEditPrice();
     g_LimitPrice=(val>0)?NormalizeDouble(val,dg):0.0;
     GlobalVariableSet(GV_LIMIT_PRICE,g_LimitPrice);
     UpdateLimitLine(); return; }

   // ── Edición del lotaje ──
   if(id==CHARTEVENT_OBJECT_ENDEDIT&&sparam==EDIT_LOT_NAME)
   { double val=ReadEditLot();
     if(val<=0)
     { Print("⚠ Lotaje inválido, se mantiene ",DoubleToString(g_Lots,2));
       RebuildActiveTab(); return;
     }
     ApplyLots(val); return; }

   if(id==CHARTEVENT_OBJECT_DRAG&&sparam==LINE_LIMIT_NAME)
   { double linePrice=ObjectGetDouble(0,LINE_LIMIT_NAME,OBJPROP_PRICE);
     g_LimitPrice=NormalizeDouble(linePrice,dg);
     if(ObjectFind(0,EDIT_PRICE_NAME)>=0)
        ObjectSetString(0,EDIT_PRICE_NAME,OBJPROP_TEXT,DoubleToString(g_LimitPrice,dg));
     GlobalVariableSet(GV_LIMIT_PRICE,g_LimitPrice);
     UpdateLimitLine(); return; }

   if(id==CHARTEVENT_OBJECT_CLICK&&sparam==LINE_LIMIT_NAME){ChartRedraw();return;}
   if(id!=CHARTEVENT_OBJECT_CLICK) return;

   if(ObjectGetInteger(0,sparam,OBJPROP_TYPE)==OBJ_BUTTON)
      ObjectSetInteger(0,sparam,OBJPROP_STATE,false);
   ChartRedraw();

   for(int t=0;t<N_TABS;t++)
      if(sparam==PFX+"TAB"+IntegerToString(t)){ActiveTab=t;RebuildActiveTab();return;}

   // ── Botonera de lotaje ──
   if(StringFind(sparam,PFX_OP+"LOTB")==0)
   { int b=(int)StringToInteger(StringSubstr(sparam,StringLen(PFX_OP+"LOTB")));
     double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP); if(step<=0) step=0.01;
     double v=g_Lots;
     if(b==0) v=g_Lots-step;
     else if(b==1) v=g_Lots+step;
     else if(b==2) v=g_Lots/2.0;
     else if(b==3) v=g_Lots*2.0;
     ApplyLots(v); return; }

   // ── Precio límite ──
   if(sparam==PFX_OP+"ASK")
   {g_LimitPrice=NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_ASK),dg);
    ObjectSetString(0,EDIT_PRICE_NAME,OBJPROP_TEXT,DoubleToString(g_LimitPrice,dg));
    GlobalVariableSet(GV_LIMIT_PRICE,g_LimitPrice); UpdateLimitLine(); return;}

   if(sparam==PFX_OP+"BID")
   {g_LimitPrice=NormalizeDouble(SymbolInfoDouble(_Symbol,SYMBOL_BID),dg);
    ObjectSetString(0,EDIT_PRICE_NAME,OBJPROP_TEXT,DoubleToString(g_LimitPrice,dg));
    GlobalVariableSet(GV_LIMIT_PRICE,g_LimitPrice); UpdateLimitLine(); return;}

   if(sparam==PFX_OP+"RST")
   {g_LimitPrice=0.0; ObjectSetString(0,EDIT_PRICE_NAME,OBJPROP_TEXT,"0");
    GlobalVariableSet(GV_LIMIT_PRICE,0.0); RemoveLimitLine(); return;}

   // ── Órdenes: siempre con el lotaje único y SL/TP fijos ──
   double lots=g_Lots;
   if(sparam==PFX_OP+"BUY"){SendMarketOrder(ORDER_TYPE_BUY,lots);return;}
   if(sparam==PFX_OP+"SELL"){SendMarketOrder(ORDER_TYPE_SELL,lots);return;}
   if(sparam==PFX_OP+"BUYLMT"){SendLimitOrder(ORDER_TYPE_BUY_LIMIT,lots,g_LimitPrice);return;}
   if(sparam==PFX_OP+"SELLLMT"){SendLimitOrder(ORDER_TYPE_SELL_LIMIT,lots,g_LimitPrice);return;}
   if(sparam==PFX_OP+"CLOSEALL"){CloseAllPositions();return;}

   if(sparam==PFX_CFG+"SAVESTATE")
   { SaveState(); ExportStateToFile(); RebuildActiveTab(); return; }

   if(sparam==PFX_POS+"SCRUP")
   {if(g_ScrollOffset>0){g_ScrollOffset--;RebuildActiveTab();}return;}
   if(sparam==PFX_POS+"SCRDN")
   {if(g_ScrollOffset+6<g_TradeCount){g_ScrollOffset++;RebuildActiveTab();}return;}
}
//+------------------------------------------------------------------+
