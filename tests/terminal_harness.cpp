// Harness de API, no un EA ni una compilación MQL5 completa.
#include <cassert>
#include <cmath>
#include <iostream>
#include <map>
#include <string>
using string = std::string;
// CONSTANTS_FROM_MQL
string GV_HIGH_WATER="hwm",GV_HIGH_WATER_LOCK="lock",_Symbol="EURUSD";
std::map<string,double> globals;
double balance=1000,backup=0,g_HighWaterBalance=0,step=.01,minimum=.01,maximum=100,InpMaxLotsPerOrder=100;
long InpMagicNumber=123;
bool persistOK=true,capital=false,statusError=false;
int backupReads=0,backupWrites=0,recalcs=0,sends=0,checks=0,deniedPermission=-1;
string message;
double MathMax(double a,double b){return std::fmax(a,b);}
double MathMin(double a,double b){return std::fmin(a,b);}
double MathAbs(double n){return std::fabs(n);}
double MathFloor(double n){return std::floor(n);}
double MathCeil(double n){return std::ceil(n);}
double NormalizeDouble(double n,int digits){double p=std::pow(10,digits);return std::round(n*p)/p;}
bool GlobalVariableCheck(string key){return globals.count(key);}
double GlobalVariableGet(string key){return globals.at(key);}
void GlobalVariableSet(string key,double n){globals[key]=n;}
bool GlobalVariableSetOnCondition(string key,double n,double expected){
    if(!globals.count(key)||globals[key]!=expected)return false;
    globals[key]=n;return true;
}
void GlobalVariablesFlush(){}
double AccountInfoDouble(int){return balance;}
double LoadHighWaterBalanceFromFile(){backupReads++;return backup;}
bool SaveHighWaterBalanceToFile(double n){assert(globals[GV_HIGH_WATER_LOCK]==1);backupWrites++;if(persistOK)backup=n;return persistOK;}
template<class... T> void Print(T...){}
void RecalcLots(){recalcs++;}
void UpdateInfoBar(){}
void RebuildActiveTab(){}
string DoubleToString(double n,int){return std::to_string(n);}
string AcctCur(){return "USD";}
bool UseCapitalBase(){return capital;}
void SetActionStatus(string text,bool error=false){message=text;statusError=error;}
bool RejectAction(string action,string reason){SetActionStatus(action+": "+reason,true);return false;}
double SymbolInfoDouble(string,int key){
    if(key==SYMBOL_VOLUME_STEP)return step;
    if(key==SYMBOL_VOLUME_MIN)return minimum;
    if(key==SYMBOL_VOLUME_MAX)return maximum;
    return 0;
}
long TerminalInfoInteger(int key){return key!=deniedPermission;}
long MQLInfoInteger(int key){return key!=deniedPermission;}
long AccountInfoInteger(int key){return key!=deniedPermission;}
void ResetLastError(){}
int GetLastError(){return 0;}
struct MqlTradeRequest {int action=0,type=0,type_filling=0,deviation=0; ulong position=0,order=0;long magic=0;double volume=0,price=0;string symbol,comment;};
struct MqlTradeCheckResult {uint retcode=0;string comment;};
struct MqlTradeResult {uint retcode=0;int retcode_external=0;string comment;};
struct MqlTick {double ask=1.1,bid=1.09;};
MqlTradeRequest lastRequest;
bool checkOK=true,sendOK=true,quotesOK=true;
uint checkCode=TRADE_RETCODE_DONE,sendCode=TRADE_RETCODE_DONE;
struct Trade {string symbol;long type;double volume;};
std::map<ulong,Trade> positions,orders;
ulong selectedPosition=0,selectedOrder=0;
bool PositionSelectByTicket(ulong ticket){selectedPosition=ticket;return positions.count(ticket);}
bool OrderSelect(ulong ticket){selectedOrder=ticket;return orders.count(ticket);}
string PositionGetString(int){return positions.at(selectedPosition).symbol;}
string OrderGetString(int){return orders.at(selectedOrder).symbol;}
long PositionGetInteger(int){return positions.at(selectedPosition).type;}
long OrderGetInteger(int){return orders.at(selectedOrder).type;}
double PositionGetDouble(int){return positions.at(selectedPosition).volume;}
bool IsManagedEntryOrderType(int,bool){return true;}
int MarketOrderFillingMode(string){return 0;}
bool SymbolInfoTick(string,MqlTick &){return quotesOK;}
bool OrderCheck(MqlTradeRequest &,MqlTradeCheckResult &result){checks++;result.retcode=checkCode;result.comment="broker check";return checkOK;}
bool OrderSend(MqlTradeRequest &req,MqlTradeResult &result){
    sends++;lastRequest=req;result.retcode=sendCode;result.comment="broker response";
    if(sendOK&&sendCode==TRADE_RETCODE_DONE){
        if(req.action==TRADE_ACTION_REMOVE)orders.erase(req.order);
        else if(req.position)positions.erase(req.position);
    }
    return sendOK;
}
// Solo se necesitan los argumentos para simular el ticket, no el formato de MT5.
template<class... T> string StringFormat(string fmt,T...){return fmt;}
// FUNCTIONS_FROM_MQL
int main(){
    globals[GV_HIGH_WATER_LOCK]=0;
    backup=1200;balance=1000;
    UpdateHighWaterBalance();assert(g_HighWaterBalance==1200&&backupReads==1);
    balance=800;ResetHighWaterBalance();assert(g_HighWaterBalance==800&&backup==800);
    assert(globals[GV_HIGH_WATER_LOCK]==0&&recalcs==1&&!statusError);
    // Una instancia antigua, incluso al guardar/salir, no puede elevar el máximo otra vez.
    g_HighWaterBalance=1200;UpdateHighWaterBalance();assert(g_HighWaterBalance==800&&backup==800);
    backup=5000;g_HighWaterBalance=5000;UpdateHighWaterBalance();assert(g_HighWaterBalance==800&&backupReads==1);
    balance=900;UpdateHighWaterBalance();assert(g_HighWaterBalance==900&&backup==900);
    balance=0;ResetHighWaterBalance();assert(backup==0&&globals[GV_HIGH_WATER]==0);
    globals.erase(GV_HIGH_WATER);g_HighWaterBalance=900;UpdateHighWaterBalance();assert(g_HighWaterBalance==0);
    // Reinicio con solo archivo y saldo inferior al máximo.
    backup=700;balance=500;globals.erase(GV_HIGH_WATER);UpdateHighWaterBalance();assert(g_HighWaterBalance==700);
    globals[GV_HIGH_WATER_LOCK]=1;int writes=backupWrites;ResetHighWaterBalance();
    assert(statusError&&backupWrites==writes&&globals[GV_HIGH_WATER]==700);
    g_HighWaterBalance=2000;UpdateHighWaterBalance();assert(g_HighWaterBalance==700&&backupWrites==writes);
    globals[GV_HIGH_WATER_LOCK]=0;persistOK=false;ResetHighWaterBalance();
    assert(statusError&&globals[GV_HIGH_WATER]==500&&globals[GV_HIGH_WATER_LOCK]==0);
    // Splits conservan el volumen, paso y límite, incluso con tres decimales.
    for(double st:{.001,.01,.1,.25}){
        step=st;
        for(int units=1;units<150;units++)for(int cap=1;cap<35;cap++){
            InpMaxLotsPerOrder=cap*step;
            int n=CalcSplitCount(units*step);double total=0;
            assert(n>0);
            for(int i=0;i<n;i++){
                double lot=CalcSplitLot(units*step,i,n);total+=lot;
                assert(lot<=InpMaxLotsPerOrder+1e-8);
                assert(std::abs(lot/step-std::round(lot/step))<1e-8);
            }
            assert(std::abs(total-units*step)<1e-8);
        }
    }
    step=0;assert(CalcSplitCount(1)==0&&CalcSplitLot(1,0,1)==0);
    step=.01;InpMaxLotsPerOrder=0;assert(CalcSplitCount(1)==0);
    // Permisos, precheck, envío, parcial y aceptación no final.
    MqlTradeRequest req;req.action=TRADE_ACTION_DEAL;
    deniedPermission=TERMINAL_TRADE_ALLOWED;assert(SendCheckedRequest(req,"BUY")==0&&sends==0&&checks==0);
    deniedPermission=-1;checkOK=false;checkCode=TRADE_RETCODE_NO_MONEY;
    assert(SendCheckedRequest(req,"BUY")==0&&sends==0&&message.find("margen")!=string::npos);
    checkOK=true;checkCode=TRADE_RETCODE_DONE;sendOK=false;sendCode=TRADE_RETCODE_MARKET_CLOSED;
    assert(SendCheckedRequest(req,"BUY")==0&&message.find("mercado cerrado")!=string::npos);
    sendOK=true;sendCode=TRADE_RETCODE_PLACED;assert(SendCheckedRequest(req,"BUY")==2&&statusError);
    req.action=TRADE_ACTION_PENDING;assert(SendCheckedRequest(req,"BUY LIMIT")==1);
    req.action=TRADE_ACTION_DEAL;
    sendCode=TRADE_RETCODE_DONE_PARTIAL;assert(SendCheckedRequest(req,"BUY")==2&&statusError);
    sendCode=TRADE_RETCODE_DONE;assert(SendCheckedRequest(req,"BUY")==1);
    // Validación por ticket/símbolo ANTES de enviar; tickets >32 bits.
    ulong ticket=5000000001UL;
    positions[ticket]={"GBPUSD",POSITION_TYPE_BUY,.25};int before=sends;
    assert(!CloseSymbolTicket(ticket,false)&&sends==before&&positions.count(ticket));
    positions[ticket].symbol=_Symbol;
    assert(CloseSymbolTicket(ticket,false)&&!positions.count(ticket));
    assert(lastRequest.position==ticket&&lastRequest.volume==.25&&lastRequest.type==ORDER_TYPE_SELL);
    positions[ticket]={_Symbol,POSITION_TYPE_SELL,.5};sendCode=TRADE_RETCODE_DONE_PARTIAL;
    assert(!CloseSymbolTicket(ticket,false)&&positions.count(ticket)&&statusError);
    assert(lastRequest.type==ORDER_TYPE_BUY);
    sendCode=TRADE_RETCODE_PLACED;assert(!CloseSymbolTicket(ticket,false)&&positions.count(ticket));
    sendCode=TRADE_RETCODE_DONE;
    orders[ticket]={"GBPUSD",0,.1};before=sends;
    assert(!CloseSymbolTicket(ticket,true)&&sends==before);
    orders[ticket].symbol=_Symbol;assert(CloseSymbolTicket(ticket,true)&&!orders.count(ticket));
    assert(lastRequest.order==ticket&&lastRequest.action==TRADE_ACTION_REMOVE);
    before=sends;assert(!CloseSymbolTicket(99999,false)&&sends==before);
    quotesOK=false;assert(!CloseSymbolTicket(ticket,false)&&sends==before);
    std::cout<<"Máximo, split, errores y cierres por ticket: regresiones OK\n";
}
