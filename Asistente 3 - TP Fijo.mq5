//+------------------------------------------------------------------+
//|                  Asistente 3 - TP Fijo.mq5   (v5.4)              |
//|                                                                  |
//|   Riesgo porcentual sobre una base: el máximo balance histórico  |
//|   (balance completo) o un capital base que arranca en un importe |
//|   fijo y solo crece con las ganancias posteriores. El porcentaje |
//|   de riesgo se define ÚNICAMENTE en las Entradas (InpRiskPercent)|
//|   y el panel lo muestra como texto informativo.                  |
//|   El monto se redondea hacia arriba a la unidad entera de la     |
//|   cuenta y la base nunca disminuye, incluso tras pérdidas.       |
//|   El lote se calcula con el divisor de puntos y se ajusta hacia  |
//|   abajo al paso del broker cuando el lote mínimo lo permite.     |
//|   El SL/TP de cada operación siguen siendo fijos; no hay trailing.|
//|   Del resto, igual que el original: linea de limite, split de    |
//|   lotes, enforce de SL/TP, JSON para el dashboard, persistencia  |
//|   y tabs OPERAR / CUENTA / POSIC / CONFIG.                       |
//+------------------------------------------------------------------+
#property copyright "Gestión Cuantitativa EA"
#property version   "5.40"
#property strict

//+------------------------------------------------------------------+
//| BASE DE CÁLCULO DEL RIESGO                                       |
//+------------------------------------------------------------------+
enum ENUM_RISK_BASE_MODE
{
   RISK_BASE_FULL_BALANCE = 0,   // Balance completo (máximo histórico)
   RISK_BASE_CAPITAL      = 1    // Capital base + ganancias acumuladas
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== STOP LOSS / TAKE PROFIT ==="
input double InpSL_Points        = 95;      // Stop Loss en puntos (fijo, sin trailing)
input double InpTP_Points        = 305;     // Take Profit en puntos (cierre directo)

input group "=== RIESGO PORCENTUAL (SOLO DESDE ENTRADAS) ==="
input double InpRiskPercent      = 4.0;     // Porcentaje de la base de riesgo por operación
input double InpRiskDivPoints    = 100;     // Puntos de división para calcular el lote
                                             // OJO: puede ser distinto del SL real de la orden

input group "=== BASE DE CÁLCULO DEL RIESGO ==="
input ENUM_RISK_BASE_MODE InpRiskBaseMode = RISK_BASE_FULL_BALANCE; // Balance completo o capital base
input double InpBaseCapital      = 0.0;     // Capital base (ej: 1500 de 10000). 0 = todo el balance

input group "=== HORARIO DE SESIÓN ==="
input bool   InpUseSessionFilter          = false;   // Filtrar nuevas entradas por horario
input string InpSessionStart              = "08:00"; // Hora del servidor del broker (HH:MM)
input string InpSessionEnd                = "17:00"; // Al terminar: cancelar LIMIT pendientes
input bool   InpCloseBeforeFridayMarketEnd = true;   // Cerrar las posiciones del EA el viernes
input int    InpFridayCloseMinutes        = 30;      // Minutos antes del cierre del símbolo
input string InpFridayMarketCloseFallback = "23:59"; // Solo si el broker no publica su horario

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
#define PNL_W             320
#define PNL_H_OPERAR      310
#define PNL_H_DETAILS     650
#define TAB_H             28
#define CONTENT_Y0        96
#define IB_CELLS          5
#define CFG_ROWS          21

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

#define GV_PREFIX         "GQP_"
string GV_RISKDIV;
string GV_DIV_INP;
string GV_HIGH_WATER;
string g_HighWaterFileName;
string GV_BASE_CAP_INP;
string GV_BASE_START;
string GV_BASE_HIGH;
string g_BaseFileName;
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
double      SL_Points;          // SL real que se envía en la orden
double      TP_Points;          // TP real que se envía en la orden
double      RiskPercent       = 4.0;   // Porcentaje aplicado a la base de riesgo
double      RiskUSD           = 0.0;   // Importe objetivo, redondeado hacia arriba
double      g_HighWaterBalance= 0.0;   // Máximo balance observado y persistido
double      g_RiskBase        = 0.0;   // Base efectiva sobre la que se aplica el porcentaje
double      g_BaseCapital     = 0.0;   // Capital base configurado (modo capital base)
double      g_BaseStartBalance= 0.0;   // Balance de referencia al crear la base
double      g_BaseHighWater   = 0.0;   // Base máxima alcanzada (nunca disminuye)
double      RiskDivPoints     = 0.0;   // Puntos divisor -> lote = RiskUSD/(pts*valorPunto)
double      g_Lots            = 0.0;   // lote calculado a partir del riesgo
int         g_LotWarn      = 0;     // 0 ok | 1 se fue al lote mínimo | 2 al máximo
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
#define OBJ_INFOBAR_RISK   "GQP_IB_RISK"
#define OBJ_INFOBAR_LOSS   "GQP_IB_LOSS"
#define OBJ_INFOBAR_GAIN   "GQP_IB_GAIN"
#define OBJ_INFOBAR_EQUITY "GQP_IB_EQUITY"
#define OBJ_INFOBAR_LOTS   "GQP_IB_LOTS"

int PNL_X, PNL_Y;
int g_PanelHeight = PNL_H_OPERAR;
int g_LastSessionCleanupDate = -1;
int g_LastFridayCloseDate = -1;
datetime g_LastSessionAttemptAt = 0;
datetime g_LastFridayAttemptAt = 0;

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
void RecalcLots();
void UpdateHighWaterBalance();
void UpdateRiskBase();
void UpdateRiskAmount();
void ResetRiskBase();
bool UseCapitalBase();
string RiskBaseLabel();
string RiskBaseShort();
void LoadBaseState();
void SaveBaseState();
string RiskPercentText();
string FmtMoney(double value);
string FmtLots(double lots);
void LogClosedTrade(const TradeRecord &rec);
void FlushClosedQueue();
void SaveState();
void ExportStateToFile();
bool ParseClock(string text,int &minutesOfDay);
bool IsWithinConfiguredSession(datetime when);
bool IsAfterConfiguredSessionEnd(datetime when);
bool GetFridayMarketClose(datetime when,datetime &marketClose);
bool CanOpenNewTrades(string actionName);
void ProcessTradingSchedule();
bool CancelManagedPendingOrders(bool includeStops);
bool CloseManagedPositions();
bool HasManagedPositions();
bool HasManagedPendingOrders(bool includeStops);

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
   json += "  \"version\": \"5.40\",\n";
   json += "  \"close_mode\": \"TP_FIJO_SIN_TRAILING\",\n";
   json += "  \"session_filter_enabled\": " + (InpUseSessionFilter ? "true" : "false") + ",\n";
   json += "  \"session_start\": \"" + InpSessionStart + "\",\n";
   json += "  \"session_end\": \"" + InpSessionEnd + "\",\n";
   json += "  \"session_end_action\": \"CANCEL_LIMIT_ORDERS\",\n";
   json += "  \"friday_close_enabled\": " + (InpCloseBeforeFridayMarketEnd ? "true" : "false") + ",\n";
   json += "  \"friday_close_minutes\": " + IntegerToString(InpFridayCloseMinutes) + ",\n";
   json += "  \"friday_close_fallback_time\": \"" + InpFridayMarketCloseFallback + "\",\n";

   // Riesgo calculado sobre la base elegida: balance completo o capital base
   string baseMode=(UseCapitalBase()?"capital_base":"full_balance");
   string lotsMode=(UseCapitalBase()?"from_capital_base_percent":"from_high_water_balance_percent");
   json += "  \"risk_percent\": " + RiskPercentText() + ",\n";
   json += "  \"risk_base_mode\": \"" + baseMode + "\",\n";
   json += "  \"risk_base\": " + DoubleToString(g_RiskBase, 2) + ",\n";
   json += "  \"risk_base_capital\": " + DoubleToString(g_BaseCapital, 2) + ",\n";
   json += "  \"risk_base_start_balance\": " + DoubleToString(g_BaseStartBalance, 2) + ",\n";
   json += "  \"high_water_balance\": " + DoubleToString(g_HighWaterBalance, 2) + ",\n";
   json += "  \"risk_usd\": " + DoubleToString(RiskUSD, 2) + ",\n";
   json += "  \"risk_div_sl_points\": " + DoubleToString(RiskDivPoints, 0) + ",\n";
   json += "  \"lots\": " + DoubleToString(g_Lots, 2) + ",\n";
   json += "  \"lots_mode\": \"" + lotsMode + "\",\n";
   json += "  \"lot_warning\": " + IntegerToString(g_LotWarn) + ",\n";
   json += "  \"limit_price\": " + DoubleToString(g_LimitPrice, 8) + ",\n";
   json += "  \"trailing_stop\": false,\n";

   // Parámetros
   json += "  \"sl_points\": " + DoubleToString(SL_Points, 1) + ",\n";
   json += "  \"tp_points\": " + DoubleToString(TP_Points, 1) + ",\n";
   json += "  \"max_lots_per_order\": " + DoubleToString(InpMaxLotsPerOrder, 1) + ",\n";
   json += "  \"split_delay_ms\": " + IntegerToString(InpSplitDelayMs) + ",\n";

   // Proyección con el SL / TP del asistente
   json += "  \"risk_target_usd\": " + DoubleToString(RiskUSD, 2) + ",\n";
   json += "  \"expected_loss\": " + DoubleToString(CalcRiskDollars(g_Lots), 2) + ",\n";
   json += "  \"expected_gain\": " + DoubleToString(CalcProfitDollars(g_Lots), 2) + ",\n";
   json += "  \"risk_percent_balance\": " + DoubleToString(RiskPercentBalance(g_Lots), 2) + ",\n";
   json += "  \"expected_loss_percent_high_water\": " + DoubleToString(ExpectedLossPercentRiskBase(g_Lots), 2) + ",\n";
   json += "  \"expected_loss_percent_risk_base\": " + DoubleToString(ExpectedLossPercentRiskBase(g_Lots), 2) + ",\n";

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

   // ── El riesgo solo se define en las Entradas ──
   // Los comandos del dashboard para cambiarlo se ignoran a propósito.
   if(ExtractJsonDouble(content, "set_risk_percent") > 0.0 ||
      ExtractJsonDouble(content, "set_risk_usd") > 0.0)
      Print("ℹ El riesgo solo se cambia desde las Entradas (InpRiskPercent); comando ignorado.");

   // ── Parsear SL de división (para el lote) ────
   double newDiv = ExtractJsonDouble(content, "set_risk_div_sl");
   if(newDiv >= 1 && MathAbs(newDiv - RiskDivPoints) > 0.0000001)
   {
      RiskDivPoints = NormalizeDouble(newDiv, 0);
      Print("📱 Dashboard cambió SL de división a: ", RiskDivPoints, " pts");
      changed = true;
   }

   if(changed) RecalcLots();

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
   string suffix=_Symbol+"_"+IntegerToString(InpMagicNumber);
   string accountServer=AccountInfoString(ACCOUNT_SERVER);
   string serverKey="";
   for(int i=0;i<StringLen(accountServer);i++)
   {
      int ch=(int)StringGetCharacter(accountServer,i);
      if((ch>='a'&&ch<='z')||(ch>='A'&&ch<='Z')||
         (ch>='0'&&ch<='9')||ch=='_')
         serverKey+=StringSubstr(accountServer,i,1);
   }
   if(StringLen(serverKey)==0) serverKey="SERVER";
   if(StringLen(serverKey)>20)
      serverKey=StringSubstr(serverKey,0,10)+
                StringSubstr(serverKey,StringLen(serverKey)-10,10);
   string accountSuffix=IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN))+"_"+
                        serverKey+"_"+AccountInfoString(ACCOUNT_CURRENCY);
   GV_RISKDIV          =GV_PREFIX+"RISKDIV_"+suffix;
   GV_DIV_INP          =GV_PREFIX+"DIVIN_"+suffix;
   GV_HIGH_WATER       =GV_PREFIX+"HWM_"+accountSuffix;
   g_HighWaterFileName ="GQP_HWM_"+accountSuffix+".dat";
   GV_BASE_CAP_INP     =GV_PREFIX+"BASCAPIN_"+accountSuffix;
   GV_BASE_START       =GV_PREFIX+"BASTART_"+accountSuffix;
   GV_BASE_HIGH        =GV_PREFIX+"BASHWM_"+accountSuffix;
   g_BaseFileName      ="GQP_BASE_"+accountSuffix+".dat";
   GV_LIMIT_PRICE      =GV_PREFIX+"LIMIT_"+suffix;
}

double LoadHighWaterBalanceFromFile()
{
   int handle=FileOpen(g_HighWaterFileName,FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle==INVALID_HANDLE) return 0.0;
   double value=0.0;
   while(!FileIsEnding(handle))
   {
      string line=FileReadString(handle);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringFind(line,"HIGH_WATER_BALANCE=")==0)
      {
         value=StringToDouble(StringSubstr(line,StringLen("HIGH_WATER_BALANCE=")));
         break;
      }
   }
   FileClose(handle);
   return value;
}

void SaveHighWaterBalanceToFile(double value)
{
   if(value<=0.0) return;
   int handle=FileOpen(g_HighWaterFileName,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(handle==INVALID_HANDLE) return;
   FileWriteString(handle,"HIGH_WATER_BALANCE="+DoubleToString(value,2)+"\n");
   FileClose(handle);
}

// Estado del capital base: capital configurado, balance de referencia y base máxima.
void LoadBaseState()
{
   double fCap=0.0,fStart=0.0,fHigh=0.0;
   int handle=FileOpen(g_BaseFileName,FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle!=INVALID_HANDLE)
   {
      while(!FileIsEnding(handle))
      {
         string line=FileReadString(handle);
         StringTrimLeft(line); StringTrimRight(line);
         if(StringFind(line,"BASE_CAPITAL_INPUT=")==0)
            fCap=StringToDouble(StringSubstr(line,StringLen("BASE_CAPITAL_INPUT=")));
         else if(StringFind(line,"BASE_START_BALANCE=")==0)
            fStart=StringToDouble(StringSubstr(line,StringLen("BASE_START_BALANCE=")));
         else if(StringFind(line,"BASE_HIGH_WATER=")==0)
            fHigh=StringToDouble(StringSubstr(line,StringLen("BASE_HIGH_WATER=")));
      }
      FileClose(handle);
   }
   if(GlobalVariableCheck(GV_BASE_START))
   {
      double gvCap  =GlobalVariableCheck(GV_BASE_CAP_INP)?GlobalVariableGet(GV_BASE_CAP_INP):0.0;
      double gvStart=GlobalVariableGet(GV_BASE_START);
      double gvHigh =GlobalVariableCheck(GV_BASE_HIGH)?GlobalVariableGet(GV_BASE_HIGH):0.0;
      if(gvStart>fStart){fStart=gvStart; fHigh=MathMax(fHigh,gvHigh); fCap=gvCap;}
   }

   // Solo se reutiliza si el capital base guardado coincide con el input actual.
   bool sameCapital=MathAbs(fCap-InpBaseCapital)<0.0000001;
   if(sameCapital&&fStart>0.0)
   {
      g_BaseStartBalance=fStart;
      g_BaseHighWater=MathMax(fHigh,g_BaseCapital);
   }
   else
   {
      g_BaseStartBalance=0.0;              // se toma en el primer UpdateRiskBase()
      g_BaseHighWater=g_BaseCapital;
      if(fStart>0.0)
         Print("🔄 Capital base cambiado a ",DoubleToString(InpBaseCapital,2)," ",AcctCur(),
               ": la base se reinicia con el balance actual.");
   }
}

void SaveBaseState()
{
   if(g_BaseStartBalance<=0.0) return;
   GlobalVariableSet(GV_BASE_CAP_INP,g_BaseCapital);
   GlobalVariableSet(GV_BASE_START,g_BaseStartBalance);
   GlobalVariableSet(GV_BASE_HIGH,g_BaseHighWater);
   int handle=FileOpen(g_BaseFileName,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(handle==INVALID_HANDLE) return;
   FileWriteString(handle,"BASE_CAPITAL_INPUT="+DoubleToString(g_BaseCapital,2)+"\n");
   FileWriteString(handle,"BASE_START_BALANCE="+DoubleToString(g_BaseStartBalance,2)+"\n");
   FileWriteString(handle,"BASE_HIGH_WATER="+DoubleToString(g_BaseHighWater,2)+"\n");
   FileClose(handle);
}

void SaveState()
{
   UpdateRiskAmount();
   GlobalVariableSet(GV_RISKDIV,RiskDivPoints);
   GlobalVariableSet(GV_DIV_INP,InpRiskDivPoints);
   GlobalVariableSet(GV_HIGH_WATER,g_HighWaterBalance);
   SaveHighWaterBalanceToFile(g_HighWaterBalance);
   SaveBaseState();
   GlobalVariableSet(GV_LIMIT_PRICE,g_LimitPrice);
   SaveStateToFile();
}

void LoadState()
{
   // El porcentaje de riesgo viene SIEMPRE de las Entradas; nada lo sobreescribe.
   RiskPercent=(InpRiskPercent>0)?NormalizeDouble(InpRiskPercent,8):0.0;
   RiskDivPoints=(InpRiskDivPoints>=1)?NormalizeDouble(InpRiskDivPoints,0):100.0;

   bool loadedGV=false;
   bool sameInputs=false;
   if(GlobalVariableCheck(GV_DIV_INP))
      sameInputs=MathAbs(GlobalVariableGet(GV_DIV_INP)-InpRiskDivPoints)<0.0000001;

   // Solo el divisor del lote admite cambios en caliente (comando del dashboard).
   if(sameInputs&&GlobalVariableCheck(GV_RISKDIV))
   {
      double savedDiv=GlobalVariableGet(GV_RISKDIV);
      if(savedDiv>=1)
      {
         RiskDivPoints=NormalizeDouble(savedDiv,0);
         loadedGV=true;
      }
   }

   double fileHighWater=LoadHighWaterBalanceFromFile();
   if(fileHighWater>g_HighWaterBalance) g_HighWaterBalance=fileHighWater;
   if(GlobalVariableCheck(GV_HIGH_WATER))
   {
      double globalHighWater=GlobalVariableGet(GV_HIGH_WATER);
      if(globalHighWater>g_HighWaterBalance) g_HighWaterBalance=globalHighWater;
   }
   if(GlobalVariableCheck(GV_LIMIT_PRICE))
   {
      double lp=GlobalVariableGet(GV_LIMIT_PRICE);
      if(lp>0.0) g_LimitPrice=lp;
   }

   // El archivo de respaldo restaura el divisor solo si sus inputs coinciden.
   if(!loadedGV) LoadStateFromFile(true);

   g_BaseCapital=(InpBaseCapital>0.0)?NormalizeDouble(InpBaseCapital,2):0.0;
   LoadBaseState();

   RecalcLots();
   Print("💰 Riesgo: ",RiskPercentText(),"% de ",RiskBaseLabel()," = ",
         DoubleToString(RiskUSD,2)," ",AcctCur(),
         " | lote: ",DoubleToString(g_Lots,2)," (",_Symbol,")");
}

string GetStateFileName()
{
   return "GQP_"+_Symbol+"_"+IntegerToString(InpMagicNumber)+".dat";
}

void SaveStateToFile()
{
   string fname=GetStateFileName();
   int handle=FileOpen(fname,FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(handle==INVALID_HANDLE) return;
   FileWriteString(handle,"RISK_PERCENT="+RiskPercentText()+"\n");
   FileWriteString(handle,"RISK_DIV="+DoubleToString(RiskDivPoints,0)+"\n");
   FileWriteString(handle,"RISK_DIV_INPUT="+DoubleToString(InpRiskDivPoints,0)+"\n");
   FileWriteString(handle,"RISK_BASE_MODE="+IntegerToString((int)InpRiskBaseMode)+"\n");
   FileWriteString(handle,"RISK_BASE_CAPITAL_INPUT="+DoubleToString(InpBaseCapital,2)+"\n");
   FileWriteString(handle,"LIMIT_PRICE="+DoubleToString(g_LimitPrice,8)+"\n");
   FileWriteString(handle,"SYMBOL="+_Symbol+"\n");
   FileWriteString(handle,"MAGIC="+IntegerToString(InpMagicNumber)+"\n");
   FileWriteString(handle,"SAVED_AT="+TimeToString(TimeCurrent())+"\n");
   FileClose(handle);
}

bool LoadStateFromFile(bool loadRiskSettings)
{
   string fname=GetStateFileName();
   if(!FileIsExist(fname)) return false;
   int handle=FileOpen(fname,FILE_READ|FILE_TXT|FILE_ANSI);
   if(handle==INVALID_HANDLE) return false;

   double savedPercent=0.0,savedDiv=0.0;
   double savedDivInput=-1.0;
   bool loadedRisk=false;
   while(!FileIsEnding(handle))
   {
      string line=FileReadString(handle);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line)==0) continue;
      int sep=StringFind(line,"=");
      if(sep<0) continue;
      string key=StringSubstr(line,0,sep);
      string val=StringSubstr(line,sep+1);
      if(key=="RISK_PERCENT") savedPercent=StringToDouble(val);
      else if(key=="RISK_DIV") savedDiv=StringToDouble(val);
      else if(key=="RISK_DIV_INPUT") savedDivInput=StringToDouble(val);
      else if(key=="LIMIT_PRICE")
      {
         double lp=StringToDouble(val);
         if(lp>0.0) g_LimitPrice=lp;
      }
   }
   FileClose(handle);

   bool sameInputs=MathAbs(savedDivInput-InpRiskDivPoints)<0.0000001;
   if(loadRiskSettings&&sameInputs&&savedDiv>=1.0)
   {
      RiskDivPoints=NormalizeDouble(savedDiv,0);
      loadedRisk=true;
   }
   return loadedRisk;
}

//+------------------------------------------------------------------+
//| CÁLCULOS                                                        |
//+------------------------------------------------------------------+
void UpdateHighWaterBalance()
{
   double currentBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   bool hasStored=GlobalVariableCheck(GV_HIGH_WATER);
   double stored=hasStored?GlobalVariableGet(GV_HIGH_WATER):0.0;
   double maximum=MathMax(g_HighWaterBalance,stored);
   if(currentBalance>maximum+0.0000001)
   {
      maximum=currentBalance;
      Print("📈 Nuevo máximo de balance: ",DoubleToString(maximum,2)," ",AcctCur());
   }
   if(maximum<=0.0&&currentBalance>0.0) maximum=currentBalance;
   if(maximum>0.0&&(!hasStored||maximum>stored+0.0000001))
      GlobalVariableSet(GV_HIGH_WATER,maximum);
   if(maximum>g_HighWaterBalance+0.0000001)
      SaveHighWaterBalanceToFile(maximum);
   g_HighWaterBalance=maximum;
}

// Base efectiva sobre la que se aplica el porcentaje de riesgo:
//   · Balance completo: el máximo balance histórico de la cuenta.
//   · Capital base: un importe fijo que solo crece con las ganancias posteriores.
void UpdateRiskBase()
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   UpdateHighWaterBalance();

   if(!UseCapitalBase())
   {
      g_RiskBase=g_HighWaterBalance;
      return;
   }

   if(g_BaseCapital<=0.0) g_BaseCapital=NormalizeDouble(InpBaseCapital,2);

   // Primera ejecución (o tras un reinicio): se fija el balance de referencia.
   if(g_BaseStartBalance<=0.0)
   {
      g_BaseStartBalance=balance;
      if(g_BaseHighWater<g_BaseCapital) g_BaseHighWater=g_BaseCapital;
      SaveBaseState();
      Print("📌 Base de riesgo creada: ",DoubleToString(g_BaseCapital,2)," ",AcctCur(),
            " | balance de referencia: ",DoubleToString(balance,2)," ",AcctCur());
   }

   // La base suma las ganancias acumuladas y nunca retrocede, aunque el balance caiga.
   double candidate=g_BaseCapital+(balance-g_BaseStartBalance);
   if(candidate<g_BaseCapital) candidate=g_BaseCapital;
   double stored=GlobalVariableCheck(GV_BASE_HIGH)?GlobalVariableGet(GV_BASE_HIGH):0.0;
   double maximum=MathMax(MathMax(g_BaseHighWater,stored),candidate);
   if(maximum>g_BaseHighWater+0.0000001||maximum>stored+0.0000001) SaveBaseState();
   g_BaseHighWater=maximum;
   g_RiskBase=maximum;
}

void UpdateRiskAmount()
{
   UpdateRiskBase();
   if(RiskPercent<=0.0||g_RiskBase<=0.0)
   {
      RiskUSD=0.0;
      return;
   }
   double rawRisk=g_RiskBase*RiskPercent/100.0;
   // Se redondea el monto hacia arriba a la unidad entera de la moneda de cuenta.
   RiskUSD=NormalizeDouble(MathMax(1.0,MathCeil(rawRisk-0.000000001)),2);
}

// Reinicia la base: vuelve al capital base con el balance actual como referencia.
void ResetRiskBase()
{
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   g_BaseCapital=(InpBaseCapital>0.0)?NormalizeDouble(InpBaseCapital,2):0.0;
   g_BaseStartBalance=(balance>0.0)?balance:0.0;
   g_BaseHighWater=g_BaseCapital;
   SaveBaseState();
   RecalcLots();
   SaveState();
   ExportStateToFile();
   Print("🔄 Base de riesgo reiniciada: ",DoubleToString(g_BaseCapital,2)," ",AcctCur(),
         " | balance de referencia: ",DoubleToString(g_BaseStartBalance,2)," ",AcctCur(),
         " | riesgo: ",DoubleToString(RiskUSD,2)," ",AcctCur(),
         " | lote: ",DoubleToString(g_Lots,2));
}

bool UseCapitalBase()
{
   return (InpRiskBaseMode==RISK_BASE_CAPITAL&&InpBaseCapital>0.0);
}

string RiskBaseShort()
{
   string cur=AcctCur();
   if(UseCapitalBase())
      return "BASE "+DoubleToString(g_BaseHighWater,2)+" "+cur+
             " (capital "+DoubleToString(g_BaseCapital,2)+" + ganancias)";
   return "MÁX. BALANCE "+DoubleToString(g_HighWaterBalance,2)+" "+cur;
}

string RiskBaseLabel()
{
   if(UseCapitalBase())
      return "la base "+DoubleToString(g_BaseCapital,2)+" "+AcctCur()+" + ganancias ("+
             DoubleToString(g_BaseHighWater,2)+" "+AcctCur()+")";
   return "el máximo balance ("+DoubleToString(g_HighWaterBalance,2)+" "+AcctCur()+")";
}

string RiskPercentText()
{
   int digits=2;
   while(digits<8&&MathAbs(RiskPercent-NormalizeDouble(RiskPercent,digits))>0.000000001)
      digits++;
   return DoubleToString(RiskPercent,digits);
}

// Importe compacto para las celdas de la barra (la moneda se indica en la cabecera).
string FmtMoney(double value)
{
   double amount=MathAbs(value);
   if(amount>=1000000.0) return DoubleToString(value/1000000.0,2)+"M";
   if(amount>=100000.0)  return DoubleToString(value/100000.0,1)+"K";
   return DoubleToString(value,2);
}

string FmtLots(double lots)
{
   string txt=DoubleToString(lots,2);
   if(g_LotWarn!=0) txt+=" ⚠";
   return txt;
}

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
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance<=0.0) return 0.0;
   return (CalcRiskDollars(lots)/balance)*100.0;
}

double ExpectedLossPercentRiskBase(double lots)
{
   if(g_RiskBase<=0.0) return 0.0;
   return (CalcRiskDollars(lots)/g_RiskBase)*100.0;
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

// Lote a partir del monto objetivo y los puntos divisores.
// Se redondea HACIA ABAJO al paso del símbolo; si el broker exige su lote mínimo
// y este supera el objetivo, se usa el mínimo y se activa g_LotWarn.
double CalcLotFromRisk(int &warn)
{
   warn = 0;
   double vpp    = ValuePerPoint();
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double stepLot= SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(vpp<=0||RiskUSD<=0||RiskPercent<=0||RiskDivPoints<1) return 0.0;
   if(stepLot <= 0) stepLot = 0.01;
   if(minLot  <= 0) minLot  = 0.01;

   double raw = RiskUSD / (RiskDivPoints * vpp);
   double lot = MathFloor(raw / stepLot) * stepLot;
   if(lot < minLot) { lot = minLot; warn = 1; }
   if(maxLot > 0 && lot > maxLot) { lot = maxLot; warn = 2; }
   int vdg=0;
   while(vdg<8&&MathAbs(stepLot-NormalizeDouble(stepLot,vdg))>0.0000000001)
      vdg++;
   return NormalizeDouble(lot,vdg);
}

void RecalcLots()
{
   UpdateRiskAmount();
   g_Lots=CalcLotFromRisk(g_LotWarn);
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
   g_PanelHeight=(ActiveTab==TAB_OPERAR)?PNL_H_OPERAR:PNL_H_DETAILS;
   ObjRect(PFX+"BG",x,y,W,g_PanelHeight,C'18,18,28',C'70,70,160',2);
   ObjRect(PFX+"TITLE_BG",x,y,W,30,C'8,8,42',C'70,70,200',1);
   ObjLbl(OBJ_TITLE,x+W/2,y+7,"  ASISTENTE 3 · TP FIJO  v5.4  ",
          clrGold,11,"Arial Bold",ANCHOR_CENTER);
   ObjLbl(PFX+"CUR",x+W-8,y+10,AcctCur(),C'150,150,190',7,"Arial Bold",ANCHOR_RIGHT_UPPER);

   int cellW=W/IB_CELLS;
   ObjRect(PFX+"IB_BG",x,y+30,W,34,C'14,22,14',C'40,80,40',1);
   string ibHdr[IB_CELLS]={"RIESGO","SI PIERDE","SI GANA","EQUIDAD","LOTE"};
   string ibObj[IB_CELLS]={OBJ_INFOBAR_RISK,OBJ_INFOBAR_LOSS,OBJ_INFOBAR_GAIN,
                           OBJ_INFOBAR_EQUITY,OBJ_INFOBAR_LOTS};
   for(int c=0;c<IB_CELLS;c++)
   {
      int cx=x+c*cellW+1,cw=(c<IB_CELLS-1)?cellW-2:W-cellW*(IB_CELLS-1)-2;
      ObjRect(PFX+"IB_C"+IntegerToString(c),cx,y+31,cw,32,C'20,30,20',C'40,70,40',1);
      ObjLbl(PFX+"IB_H"+IntegerToString(c),cx+cw/2,y+33,ibHdr[c],clrSilver,7,"Arial",ANCHOR_CENTER);
      ObjLbl(ibObj[c],cx+cw/2,y+42,"---",clrWhite,9,"Arial Bold",ANCHOR_CENTER);
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
   ObjRect(PFX+"CONTENT_BG",x,y+CONTENT_Y0,W,g_PanelHeight-CONTENT_Y0-6,C'22,22,34',C'55,55,110',1);
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
   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity =AccountInfoDouble(ACCOUNT_EQUITY);
   double loss   =CalcRiskDollars(g_Lots);
   double gain   =CalcProfitDollars(g_Lots);

   ObjectSetString(0,OBJ_INFOBAR_RISK,OBJPROP_TEXT,FmtMoney(RiskUSD));
   ObjectSetInteger(0,OBJ_INFOBAR_RISK,OBJPROP_COLOR,(g_LotWarn==0)?clrGold:clrOrange);

   ObjectSetString(0,OBJ_INFOBAR_LOSS,OBJPROP_TEXT,"-"+FmtMoney(loss));
   ObjectSetInteger(0,OBJ_INFOBAR_LOSS,OBJPROP_COLOR,clrTomato);

   ObjectSetString(0,OBJ_INFOBAR_GAIN,OBJPROP_TEXT,"+"+FmtMoney(gain));
   ObjectSetInteger(0,OBJ_INFOBAR_GAIN,OBJPROP_COLOR,clrLimeGreen);

   ObjectSetString(0,OBJ_INFOBAR_EQUITY,OBJPROP_TEXT,FmtMoney(equity));
   ObjectSetInteger(0,OBJ_INFOBAR_EQUITY,OBJPROP_COLOR,(equity>=balance)?clrLimeGreen:clrTomato);

   ObjectSetString(0,OBJ_INFOBAR_LOTS,OBJPROP_TEXT,FmtLots(g_Lots));
   ObjectSetInteger(0,OBJ_INFOBAR_LOTS,OBJPROP_COLOR,(g_LotWarn==0)?clrWhite:clrOrange);
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
   ChartRedraw();
}

void RebuildActiveTab()
{
   int desiredHeight=(ActiveTab==TAB_OPERAR)?PNL_H_OPERAR:PNL_H_DETAILS;
   if(desiredHeight!=g_PanelHeight)
   {
      g_PanelHeight=desiredHeight;
      ObjectSetInteger(0,PFX+"BG",OBJPROP_YSIZE,g_PanelHeight);
      ObjectSetInteger(0,PFX+"CONTENT_BG",OBJPROP_YSIZE,g_PanelHeight-CONTENT_Y0-6);
   }
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
   int x=PNL_X,W=PNL_W,y=PNL_Y+CONTENT_Y0+8;
   int cx=x+8,cw=W-16;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   // El riesgo es informativo: solo se cambia desde las Entradas (InpRiskPercent).
   ObjRect(PFX_OP+"RISK_BG",cx,y,cw,34,C'30,28,18',C'95,90,45',1);
   ObjLbl(PFX_OP+"RISK_L1",cx+6,y+3,
      "RIESGO "+RiskPercentText()+"% · "+RiskBaseShort(),clrGold,8,"Arial Bold");
   ObjLbl(PFX_OP+"RISK_L2",cx+6,y+17,
      "Fijo: cámbialo solo en Entradas · "+DoubleToString(RiskUSD,2)+" "+AcctCur()+
      " · lote "+DoubleToString(g_Lots,2),
      C'160,160,190',7,"Arial");
   y+=42;

   // Precio único que usan BUY LIMIT y SELL LIMIT.
   ObjLbl(PFX_OP+"LIMIT_LABEL",cx+2,y,"PRECIO PARA ORDEN LIMIT",clrSilver,8,"Arial Bold");
   y+=15;
   ObjEdit(EDIT_PRICE_NAME,cx,y,cw,28,
      (g_LimitPrice>0)?DoubleToString(g_LimitPrice,dg):"0",C'30,30,48',clrWhite,10);
   y+=32;

   int quickW=(cw-4)/2;
   ObjBtn(PFX_OP+"ASK",cx,y,quickW,21,"USAR ASK",C'0,70,110',clrWhite,8,"Arial");
   ObjBtn(PFX_OP+"BID",cx+quickW+4,y,quickW,21,"USAR BID",C'110,55,0',clrWhite,8,"Arial");
   y+=28;

   int obw=(cw-4)/2;
   ObjBtn(PFX_OP+"BUY",cx,y,obw,42,"BUY",C'0,145,0',clrWhite,12);
   ObjBtn(PFX_OP+"SELL",cx+obw+4,y,obw,42,"SELL",C'190,0,0',clrWhite,12);
   y+=48;
   ObjBtn(PFX_OP+"BUYLMT",cx,y,obw,34,"BUY LIMIT",C'0,105,75',clrWhite,9);
   ObjBtn(PFX_OP+"SELLLMT",cx+obw+4,y,obw,34,"SELL LIMIT",C'160,50,0',clrWhite,9);
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
   BuildCuentaRow(PFX_ACC+"BASE",cx,y,cw,34,"BASE DE RIESGO ("+RiskPercentText()+"%)",
      StringFormat("%.2f %s",g_RiskBase,cur),C'32,30,18',C'90,85,45',clrGold); y+=38;
   BuildCuentaRow(PFX_ACC+"LOTE",cx,y,cw,34,"LOTE PRÓXIMA OPERACIÓN",FmtLots(g_Lots),
      C'32,30,18',C'90,85,45',(g_LotWarn==0)?clrWhite:clrOrange); y+=38;
   BuildCuentaRow(PFX_ACC+"MRG",cx,y,cw,34,"MARGEN",StringFormat("%.2f %s",margin,cur),C'20,25,40',C'45,55,90',clrOrange); y+=38;
   BuildCuentaRow(PFX_ACC+"FM",cx,y,cw,34,"LIBRE",StringFormat("%.2f %s",freeMrg,cur),C'20,25,40',C'45,55,90',(freeMrg<balance*0.20)?clrTomato:clrLimeGreen); y+=38;

   string mTxt; color mC;
   if(margin<=0) {mTxt="N/A";mC=clrSilver;}
   else if(mrgLv>=200) {mTxt=StringFormat("%.0f%%",mrgLv);mC=clrLimeGreen;}
   else if(mrgLv>=120) {mTxt=StringFormat("%.0f%%",mrgLv);mC=clrYellow;}
   else {mTxt=StringFormat("%.0f%%",mrgLv);mC=clrTomato;}
   BuildCuentaRow(PFX_ACC+"MPC",cx,y,cw,34,"NIVEL MARGEN",mTxt,C'20,25,40',C'45,55,90',mC); y+=42;

   // Proyección con el lote calculado por riesgo y el SL/TP del asistente
   double rl=CalcRiskDollars(g_Lots), gl=CalcProfitDollars(g_Lots);
   BuildCuentaRow(PFX_ACC+"EXPR",cx,y,cw,34,"RIESGO POR OPERACIÓN",StringFormat("%.2f %s  (%s%%)",RiskUSD,cur,RiskPercentText()),C'32,30,18',C'90,85,45',clrGold); y+=38;
   BuildCuentaRow(PFX_ACC+"EXP",cx,y,cw,34,StringFormat("SI TOCA TP (%.0f pts)",TP_Points),StringFormat("+%.2f %s",gl,cur),C'18,32,18',C'45,90,45',clrLimeGreen); y+=38;
   BuildCuentaRow(PFX_ACC+"EXPL",cx,y,cw,34,StringFormat("SI TOCA SL (%.0f pts)",SL_Points),StringFormat("-%.2f %s",rl,cur),C'32,18,18',C'90,45,45',clrTomato); y+=38;

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
   double pctBase=(g_RiskBase>0)?(riskUSD/g_RiskBase)*100.0:0.0;
   string loteTxt=StringFormat("%.2f",g_Lots);
   if(g_LotWarn==1) loteTxt+=" ⚠MIN";
   if(g_LotWarn==2) loteTxt+=" ⚠MAX";
   string baseModeTxt=UseCapitalBase()?"Capital base":"Balance completo";
   string baseCapitalTxt=UseCapitalBase()?StringFormat("%.2f %s",g_BaseCapital,cur):"no aplica";
   string baseStartTxt=(g_BaseStartBalance>0.0)?StringFormat("%.2f %s",g_BaseStartBalance,cur):"no aplica";

   string cfgL[CFG_ROWS],cfgV[CFG_ROWS]; color cfgC[CFG_ROWS];
   cfgL[0]="Simbolo"; cfgV[0]=_Symbol; cfgC[0]=clrWhite;
   cfgL[1]="Magic"; cfgV[1]=IntegerToString(InpMagicNumber); cfgC[1]=clrYellow;
   cfgL[2]="SL de la orden"; cfgV[2]=StringFormat("%.0f pts",SL_Points); cfgC[2]=clrTomato;
   cfgL[3]="TP de la orden"; cfgV[3]=StringFormat("%.0f pts",TP_Points); cfgC[3]=clrDodgerBlue;
   cfgL[4]="R:R"; cfgV[4]=StringFormat("1:%.2f",TP_Points/MathMax(SL_Points,1)); cfgC[4]=clrMagenta;
   cfgL[5]="Riesgo por op."; cfgV[5]=StringFormat("%.2f %s / %s%%",RiskUSD,cur,RiskPercentText()); cfgC[5]=clrGold;
   cfgL[6]="SL de división"; cfgV[6]=StringFormat("%.0f pts",RiskDivPoints); cfgC[6]=clrGold;
   cfgL[7]="Lote calculado"; cfgV[7]=loteTxt; cfgC[7]=(g_LotWarn==0)?clrLimeGreen:clrOrange;
   cfgL[8]="Pierde con SL"; cfgV[8]=StringFormat("-%.2f %s (%.2f%%)",riskUSD,cur,pctBase); cfgC[8]=clrTomato;
   cfgL[9]="Gana con TP"; cfgV[9]=StringFormat("+%.2f %s",profitUSD,cur); cfgC[9]=clrLimeGreen;
   cfgL[10]="Modo de base"; cfgV[10]=baseModeTxt; cfgC[10]=UseCapitalBase()?clrGold:clrDodgerBlue;
   cfgL[11]="Base de riesgo"; cfgV[11]=StringFormat("%.2f %s",g_RiskBase,cur); cfgC[11]=clrGold;
   cfgL[12]="Capital base"; cfgV[12]=baseCapitalTxt; cfgC[12]=clrGold;
   cfgL[13]="Balance de referencia"; cfgV[13]=baseStartTxt; cfgC[13]=clrSilver;
   cfgL[14]="Cierre"; cfgV[14]="TP FIJO · SIN TRAILING"; cfgC[14]=clrGold;
   cfgL[15]="Horario de sesión";
   cfgV[15]=InpUseSessionFilter?(InpSessionStart+" - "+InpSessionEnd):"Sin filtro";
   cfgC[15]=InpUseSessionFilter?clrDodgerBlue:clrSilver;
   cfgL[16]="Cierre viernes";
   cfgV[16]=InpCloseBeforeFridayMarketEnd?StringFormat("%d min antes del mercado",InpFridayCloseMinutes):"Desactivado";
   cfgC[16]=InpCloseBeforeFridayMarketEnd?clrGold:clrSilver;
   cfgL[17]="Máximo balance";
   cfgV[17]=StringFormat("%.2f %s",g_HighWaterBalance,cur);
   cfgC[17]=clrDodgerBlue;
   cfgL[18]="Login"; cfgV[18]=IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)); cfgC[18]=clrYellow;
   cfgL[19]="Broker"; cfgV[19]=AccountInfoString(ACCOUNT_COMPANY); cfgC[19]=clrSilver;
   cfgL[20]="Archivo estado"; cfgV[20]=g_StateFileName; cfgC[20]=clrSilver;

   for(int i=0;i<CFG_ROWS;i++)
   {
      color bg=(i%2==0)?C'24,24,36':C'20,20,30';
      ObjRect(PFX_CFG+"ROW"+IntegerToString(i),cx,y,cw,20,bg,bg,0);
      ObjLbl(PFX_CFG+"LH"+IntegerToString(i),cx+4,y+4,cfgL[i],clrSilver,8,"Arial");
      ObjLbl(PFX_CFG+"LV"+IntegerToString(i),cx+cw-4,y+4,cfgV[i],cfgC[i],8,"Arial Bold",ANCHOR_RIGHT_UPPER);
      y+=20;
   }

   ObjSep(PFX_CFG+"S2",cx,y,cw); y+=6;
   int cfgBtnW=(cw-4)/2;
   ObjBtn(PFX_CFG+"SAVESTATE",cx,y,cfgBtnW,24,"💾 Guardar estado",C'30,80,30',clrWhite,8,"Arial Bold");
   ObjBtn(PFX_CFG+"RESETBASE",cx+cfgBtnW+4,y,cfgBtnW,24,"⟲ Reiniciar base",C'95,60,20',clrWhite,8,"Arial Bold");
   y+=30;
   ObjRect(PFX_CFG+"NOTE_BG",cx,y,cw,56,C'24,32,24',C'50,100,50',1);
   ObjLbl(PFX_CFG+"NOTE1",cx+6,y+4,"Lote = monto objetivo / (pts divisor x valor punto/lote).",clrLimeGreen,7,"Arial");
   ObjLbl(PFX_CFG+"NOTE2",cx+6,y+16,"El SL de división SOLO calcula el lote; el SL de la orden es otro",clrSilver,7,"Arial");
   ObjLbl(PFX_CFG+"NOTE3",cx+6,y+28,"y NUNCA se mueve. Riesgo = InpRiskPercent % de la base: solo",clrSilver,7,"Arial");
   ObjLbl(PFX_CFG+"NOTE4",cx+6,y+40,"se cambia en las Entradas. La base sube con ganancias, nunca baja.",clrGold,7,"Arial");
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
//| HORARIO DE SESIÓN Y CIERRE DEL VIERNES                         |
//+------------------------------------------------------------------+
datetime ServerNow()
{
   datetime now=TimeTradeServer();
   if(now<=0) now=TimeCurrent();
   return now;
}

ENUM_ORDER_TYPE_FILLING MarketOrderFillingMode(string symbol)
{
   long modes=SymbolInfoInteger(symbol,SYMBOL_FILLING_MODE);
   if((modes&SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
   if((modes&SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
   return ORDER_FILLING_IOC;
}

int DateKey(datetime when)
{
   MqlDateTime dt;
   if(!TimeToStruct(when,dt)) return -1;
   return dt.year*10000+dt.mon*100+dt.day;
}

bool ParseClock(string text,int &minutesOfDay)
{
   StringTrimLeft(text);
   StringTrimRight(text);
   int colon=StringFind(text,":");
   if(colon<1||colon>=StringLen(text)-1) return false;
   string hourText=StringSubstr(text,0,colon);
   string minuteText=StringSubstr(text,colon+1);
   for(int i=0;i<StringLen(hourText);i++)
   {
      int ch=StringGetCharacter(hourText,i);
      if(ch<'0'||ch>'9') return false;
   }
   for(int i=0;i<StringLen(minuteText);i++)
   {
      int ch=StringGetCharacter(minuteText,i);
      if(ch<'0'||ch>'9') return false;
   }
   int hour=(int)StringToInteger(hourText);
   int minute=(int)StringToInteger(minuteText);
   if(hour<0||hour>23||minute<0||minute>59) return false;
   minutesOfDay=hour*60+minute;
   return true;
}

bool GetSessionBounds(int &startMinute,int &endMinute)
{
   return ParseClock(InpSessionStart,startMinute)&&ParseClock(InpSessionEnd,endMinute);
}

bool IsWithinConfiguredSession(datetime when)
{
   if(!InpUseSessionFilter) return true;
   int startMinute,endMinute;
   if(!GetSessionBounds(startMinute,endMinute)) return false;
   if(startMinute==endMinute) return true; // horario igual: sesión continua
   MqlDateTime dt;
   if(!TimeToStruct(when,dt)) return false;
   int nowMinute=dt.hour*60+dt.min;
   if(startMinute<endMinute)
      return (nowMinute>=startMinute&&nowMinute<endMinute);
   return (nowMinute>=startMinute||nowMinute<endMinute); // cruza medianoche
}

bool IsAfterConfiguredSessionEnd(datetime when)
{
   if(!InpUseSessionFilter) return false;
   int startMinute,endMinute;
   if(!GetSessionBounds(startMinute,endMinute)||startMinute==endMinute) return false;
   MqlDateTime dt;
   if(!TimeToStruct(when,dt)) return false;
   int nowMinute=dt.hour*60+dt.min;
   if(startMinute<endMinute) return nowMinute>=endMinute;
   // Para horarios nocturnos, el cierre diario ocurre entre end y start.
   return (nowMinute>=endMinute&&nowMinute<startMinute);
}

bool GetFridayMarketClose(datetime when,datetime &marketClose)
{
   MqlDateTime dt;
   if(!TimeToStruct(when,dt)||dt.day_of_week!=FRIDAY) return false;
   if(DateKey(when)<0) return false;

   dt.hour=0;
   dt.min=0;
   dt.sec=0;
   datetime dayStart=StructToTime(dt);
   long latestCloseSeconds=-1;

   // MT5 publica los horarios de negociación del símbolo en hora del servidor.
   for(uint session=0;session<24;session++)
   {
      datetime from=0,to=0;
      if(!SymbolInfoSessionTrade(_Symbol,FRIDAY,session,from,to)) break;
      long fromRaw=(long)from;
      long toRaw=(long)to;
      long fromSeconds=fromRaw%86400;
      long toSeconds=toRaw%86400;
      if(fromSeconds<0) fromSeconds+=86400;
      if(toSeconds<0) toSeconds+=86400;
      if(toRaw>=86400&&toSeconds==0) toSeconds=86400;
      if(toSeconds==0&&fromSeconds>0) toSeconds=86400; // cierre a medianoche
      if(fromSeconds==0&&toSeconds==0) continue;       // horario no publicado
      if(toSeconds<=fromSeconds) toSeconds+=86400;     // sesión termina el sábado
      if(toSeconds>latestCloseSeconds) latestCloseSeconds=toSeconds;
   }

   if(latestCloseSeconds>=0)
   {
      marketClose=dayStart+(datetime)latestCloseSeconds;
      return true;
   }

   // Algunos brokers no devuelven sesiones: se usa la hora de respaldo configurable.
   int fallbackMinute;
   if(!ParseClock(InpFridayMarketCloseFallback,fallbackMinute)) return false;
   marketClose=dayStart+(datetime)(fallbackMinute*60);
   return true;
}

bool CanOpenNewTrades(string actionName)
{
   datetime now=ServerNow();
   RecalcLots();
   if(RiskPercent<=0||RiskUSD<=0||g_Lots<=0)
   {
      Print("⏸ ",actionName," rechazado: porcentaje de riesgo o lote inválido.");
      return false;
   }
   if(InpUseSessionFilter&&!IsWithinConfiguredSession(now))
   {
      Print("⏸ ",actionName," rechazado: fuera del horario configurado (hora servidor).");
      return false;
   }
   if(InpCloseBeforeFridayMarketEnd)
   {
      datetime marketClose;
      if(GetFridayMarketClose(now,marketClose))
      {
         int minutes=(int)MathMax(1,MathMin(InpFridayCloseMinutes,1440));
         if(now>=marketClose-minutes*60)
         {
            Print("⏸ ",actionName," rechazado: cierre preventivo del viernes activo.");
            return false;
         }
      }
   }
   return true;
}

bool IsManagedEntryOrderType(int type,bool includeStops)
{
   if(type==ORDER_TYPE_BUY_LIMIT||type==ORDER_TYPE_SELL_LIMIT) return true;
   if(!includeStops) return false;
   return (type==ORDER_TYPE_BUY_STOP||type==ORDER_TYPE_SELL_STOP||
           type==ORDER_TYPE_BUY_STOP_LIMIT||type==ORDER_TYPE_SELL_STOP_LIMIT);
}

bool CancelManagedPendingOrders(bool includeStops)
{
   bool allRemoved=true;
   int removed=0;
   for(int i=OrdersTotal()-1;i>=0;i--)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0||!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber) continue;
      int type=(int)OrderGetInteger(ORDER_TYPE);
      if(!IsManagedEntryOrderType(type,includeStops)) continue;

      MqlTradeRequest req={};
      MqlTradeResult res={};
      req.action=TRADE_ACTION_REMOVE;
      req.order=ticket;
      req.symbol=_Symbol;
      req.magic=InpMagicNumber;
      if(!OrderSend(req,res)||res.retcode!=TRADE_RETCODE_DONE)
      {
         Print("⚠ No se pudo cancelar orden pendiente #",ticket,". Retcode: ",res.retcode,
               " | error: ",GetLastError());
         allRemoved=false;
      }
      else removed++;
   }
   if(removed>0)
   {
      string kinds=includeStops?"LIMIT/STOP":"LIMIT";
      Print("🧹 Canceladas ",removed," órdenes pendientes ",kinds," de ",_Symbol,".");
   }
   return allRemoved;
}

bool CloseManagedPositions()
{
   bool allClosed=true;
   int sent=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0||!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      string symbol=PositionGetString(POSITION_SYMBOL);
      double volume=PositionGetDouble(POSITION_VOLUME);
      long type=PositionGetInteger(POSITION_TYPE);

      MqlTradeRequest req={};
      MqlTradeResult res={};
      req.action=TRADE_ACTION_DEAL;
      req.position=ticket;
      req.symbol=symbol;
      req.volume=volume;
      req.deviation=20;
      req.magic=InpMagicNumber;
      req.comment="FRIDAY_CLOSE";
      req.type_filling=MarketOrderFillingMode(symbol);
      if(type==POSITION_TYPE_BUY)
      {
         req.type=ORDER_TYPE_SELL;
         req.price=SymbolInfoDouble(symbol,SYMBOL_BID);
      }
      else
      {
         req.type=ORDER_TYPE_BUY;
         req.price=SymbolInfoDouble(symbol,SYMBOL_ASK);
      }
      if(!OrderSend(req,res)||(res.retcode!=TRADE_RETCODE_DONE&&res.retcode!=TRADE_RETCODE_DONE_PARTIAL))
      {
         Print("⚠ No se pudo cerrar posición #",ticket," antes del cierre del mercado. Retcode: ",
               res.retcode," | error: ",GetLastError());
         allClosed=false;
      }
      else sent++;
   }
   if(sent>0) Print("🔔 Cierre preventivo del viernes: enviadas ",sent," solicitudes de cierre.");
   return allClosed;
}

bool HasManagedPositions()
{
   for(int i=0;i<PositionsTotal();i++)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0||!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)==_Symbol&&
         PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) return true;
   }
   return false;
}

bool HasManagedPendingOrders(bool includeStops)
{
   for(int i=0;i<OrdersTotal();i++)
   {
      ulong ticket=OrderGetTicket(i);
      if(ticket==0||!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL)!=_Symbol||
         OrderGetInteger(ORDER_MAGIC)!=InpMagicNumber) continue;
      int type=(int)OrderGetInteger(ORDER_TYPE);
      if(IsManagedEntryOrderType(type,includeStops)) return true;
   }
   return false;
}

void ProcessTradingSchedule()
{
   datetime now=ServerNow();
   int today=DateKey(now);

   if(InpUseSessionFilter&&IsAfterConfiguredSessionEnd(now)&&today>=0&&
      g_LastSessionCleanupDate!=today&&
      (g_LastSessionAttemptAt==0||now-g_LastSessionAttemptAt>=5||now<g_LastSessionAttemptAt))
   {
      g_LastSessionAttemptAt=now;
      bool removed=CancelManagedPendingOrders(false);
      if(removed&&!HasManagedPendingOrders(false))
      {
         g_LastSessionCleanupDate=today;
         Print("⏹ Fin de sesión: órdenes LIMIT canceladas; las posiciones permanecen abiertas.");
      }
   }

   if(!InpCloseBeforeFridayMarketEnd||today<0) return;
   datetime marketClose;
   if(!GetFridayMarketClose(now,marketClose)) return;
   int minutes=(int)MathMax(1,MathMin(InpFridayCloseMinutes,1440));
   datetime cutoff=marketClose-minutes*60;
   if(now<cutoff||now>=marketClose||g_LastFridayCloseDate==today) return;
   if(g_LastFridayAttemptAt!=0&&now-g_LastFridayAttemptAt<10&&now>=g_LastFridayAttemptAt) return;

   g_LastFridayAttemptAt=now;
   bool ordersOK=CancelManagedPendingOrders(true);
   bool positionsOK=CloseManagedPositions();
   if(ordersOK&&positionsOK&&!HasManagedPendingOrders(true)&&!HasManagedPositions())
   {
      g_LastFridayCloseDate=today;
      Print("✅ Cierre del viernes completado: posiciones cerradas y órdenes LIMIT/STOP canceladas, ",
            minutes," minutos antes del cierre de mercado.");
   }
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
   req.type_filling=MarketOrderFillingMode(_Symbol);
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
   if(!CanOpenNewTrades((ot==ORDER_TYPE_BUY)?"BUY":"SELL")) return false;
   totalLots=g_Lots;
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
   if(!CanOpenNewTrades((ot==ORDER_TYPE_BUY_LIMIT)?"BUY LIMIT":"SELL LIMIT")) return false;
   totalLots=g_Lots;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   if(lp<=0)
   {
      Print("⚠ Ingrese un precio válido en el campo PRECIO PARA ORDEN LIMIT.");
      return false;
   }
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

   if(InpRiskPercent<=0)
      Print("⚠ InpRiskPercent debe ser mayor que cero; las entradas quedarán bloqueadas.");
   if(InpRiskBaseMode==RISK_BASE_CAPITAL&&InpBaseCapital<=0.0)
      Print("⚠ InpRiskBaseMode = Capital base pero InpBaseCapital es 0; se usa el balance completo.");
   if(UseCapitalBase())
      Print("📌 Capital base ",DoubleToString(InpBaseCapital,2)," ",AcctCur(),
            ": el porcentaje se aplica sobre esa base mas las ganancias, no sobre el balance completo.");
   if(InpUseSessionFilter)
   {
      int sessionStart,sessionEnd;
      if(!GetSessionBounds(sessionStart,sessionEnd))
         Print("⚠ Horario de sesión inválido. Use HH:MM en hora del servidor; no se permitirán nuevas entradas.");
   }
   int fallbackCloseMinute;
   if(!ParseClock(InpFridayMarketCloseFallback,fallbackCloseMinute))
      Print("⚠ Hora de respaldo del cierre del viernes inválida; se requiere HH:MM.");
   if(!EventSetTimer(1)) Print("⚠ No se pudo iniciar el temporizador del horario. Error: ",GetLastError());
   ProcessTradingSchedule();

   // Exportar estado inicial
   ExportStateToFile();

   Print("EA v5.40 TP FIJO (sin trailing) | Riesgo ",RiskPercentText(),"% de ",RiskBaseLabel(),
         " = ",DoubleToString(RiskUSD,2)," ",AcctCur()," por op",
         " | SL división ", DoubleToString(RiskDivPoints,0), " pts -> lote ", DoubleToString(g_Lots,2),
         " | SL orden ", DoubleToString(SL_Points,0), " pts | TP ", DoubleToString(TP_Points,0), " pts",
         " | ", _Symbol, " | Magic: ", IntegerToString(InpMagicNumber),
         " | Login: ", IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                        |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
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
   int prevCount=g_TradeCount;
   double prevLot=g_Lots;
   double prevRiskBase=g_RiskBase;
   ProcessTradingSchedule();

   // Actualiza el máximo balance persistente y procesa comandos del Dashboard.
   RecalcLots();
   ReadCommandsFromFile();

   // ── Lógica del asistente ──
   RecalcLots();               // el lote depende del riesgo calculado y del tick value
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

   if(g_TradeCount!=prevCount||MathAbs(g_Lots-prevLot)>0.0000001||
      MathAbs(g_RiskBase-prevRiskBase)>0.0000001)
   {
      if(MathAbs(g_RiskBase-prevRiskBase)>0.0000001) ExportStateToFile();
      RebuildActiveTab();
   }
   else if(ActiveTab==TAB_CUENTA||ActiveTab==TAB_POSIC)
   {
      DeleteContentObjects();
      if(ActiveTab==TAB_CUENTA) BuildTabCuenta();
      if(ActiveTab==TAB_POSIC) BuildTabPosiciones();
      ChartRedraw();
   }
}

// Timer para ejecutar los cierres aunque el símbolo deje de recibir ticks.
void OnTimer()
{
   int previousCount=g_TradeCount;
   double previousLots=g_Lots;
   double previousRiskBase=g_RiskBase;
   ProcessTradingSchedule();
   RecalcLots();
   SyncAllTrades();
   FlushClosedQueue();
   UpdateInfoBar();
   if(g_TradeCount!=previousCount||MathAbs(g_Lots-previousLots)>0.0000001||
      MathAbs(g_RiskBase-previousRiskBase)>0.0000001)
   {
      ExportStateToFile();
      RebuildActiveTab();
   }
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
   if(sparam==PFX_CFG+"SAVESTATE")
   { SaveState(); ExportStateToFile(); RebuildActiveTab(); return; }

   // Reinicia el capital base tomando el balance actual como referencia.
   if(sparam==PFX_CFG+"RESETBASE")
   {
      if(!UseCapitalBase())
         Print("⚠ Reiniciar base solo aplica con InpRiskBaseMode = Capital base e InpBaseCapital > 0.");
      else
      { ResetRiskBase(); UpdateInfoBar(); RebuildActiveTab(); }
      return;
   }

   if(sparam==PFX_POS+"SCRUP")
   {if(g_ScrollOffset>0){g_ScrollOffset--;RebuildActiveTab();}return;}
   if(sparam==PFX_POS+"SCRDN")
   {if(g_ScrollOffset+6<g_TradeCount){g_ScrollOffset++;RebuildActiveTab();}return;}
}
//+------------------------------------------------------------------+
