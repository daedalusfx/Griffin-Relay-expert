//+------------------------------------------------------------------+
//|                                       Griffin-Relay-expert.mq5   |
//|      V3.0 - Ultra-Fast WebSocket DLL Integration (HFT Ready)     |
//+------------------------------------------------------------------+
#property copyright "Griffin Quant"
#property link      "https://github.com/daedalusfx"
#property version   "3.00"

#include <Trade\Trade.mqh>

// --- ایمپورت توابع DLL (مربوط به اکسپرت Slave) ---
#import "GriffinLensClient\\libGriffinLensClient.dll"
   void InitializeService();
   void FinalizeService();
   int  GetNextCommand(uchar& buffer[], int buffer_size);
#import

// --- ورودی‌های اکسپرت ---
input group "Copy Trading Settings"
input double InpRiskPercent    = 1.0;     // درصد ریسک برای هر معامله
input ulong  InpMagicNumber    = 17560;   // مجیک نامبر اکسپرت اسلیو

input group "System Settings"
input int    InpTimerMs        = 20;      // سرعت اسکن سوکت (۲۰ میلی‌ثانیه برای HFT)

// --- متغیرهای سراسری ---
CTrade trade;
ulong g_master_tickets[]; // برای ذخیره تیکت‌های حساب Master
ulong g_slave_tickets[];  // برای ذخیره تیکت‌های معادل در حساب Slave

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetMarginMode();
   
   // راه‌اندازی DLL کلاینت
   InitializeService();
   
   // تایمر HFT برای بررسی صف دستورات
   EventSetMillisecondTimer(InpTimerMs);
   
   Print("🚀 Griffin Relay Initialized. Polling DLL every ", InpTimerMs, "ms.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   FinalizeService(); 
   Print("🛑 Griffin Relay Deinitialized.");
}

//+------------------------------------------------------------------+
void OnTimer()
{
   uchar buffer[2048]; // بافر برای خواندن پیام از DLL
   
   while(true)
   {
       ArrayInitialize(buffer, 0);
       
       // دریافت دستور از DLL
       int len = GetNextCommand(buffer, 2048);
       
       if(len <= 0) break; // صف خالی است
       
       // تبدیل بایت‌های دریافتی به استرینگ
       string msg = CharArrayToString(buffer, 0, len, CP_UTF8);
       
       // پردازش سیگنال
       ProcessSingleSignal(msg);
   }
}

//+------------------------------------------------------------------+
void ProcessSingleSignal(string json)
{
    StringTrimLeft(json);
    StringTrimRight(json);
    if(json == "") return;

    string type = GetJsonString(json, "type");
    if(type != "trade_signal") return; 

    string signal_action     = GetJsonString(json, "action");
    ulong  signal_ticket     = GetJsonUlong(json, "provider_ticket");
    string signal_symbol     = GetJsonString(json, "symbol");
    int    signal_order_type = (int)GetJsonUlong(json, "order_type");
    double signal_price      = GetJsonDouble(json, "price");
    double signal_sl         = GetJsonDouble(json, "sl");
    double signal_tp         = GetJsonDouble(json, "tp");

    if(signal_symbol != _Symbol) return;

    // --- باز کردن معامله ---
    if(signal_action == "PLACE_PENDING" || signal_action == "OPEN_POSITION")
    {
        if(FindSlaveTicketByMasterTicket(signal_ticket) > 0) return; // جلوگیری از تکرار
        
        double lot_size = CalculateLotSizeByRisk(signal_price, signal_sl);
        if(lot_size > 0)
        {
           bool success = false;
           if(signal_action == "PLACE_PENDING") {
              success = trade.OrderOpen(signal_symbol, (ENUM_ORDER_TYPE)signal_order_type, lot_size, 0, signal_price, signal_sl, signal_tp, ORDER_TIME_GTC, 0, "");
           } else {
              if((ENUM_POSITION_TYPE)signal_order_type == POSITION_TYPE_BUY)
                 success = trade.Buy(lot_size, signal_symbol, 0, signal_sl, signal_tp);
              else
                 success = trade.Sell(lot_size, signal_symbol, 0, signal_sl, signal_tp);
           }

           if(success)
           {
               ulong new_slave_ticket = (signal_action == "PLACE_PENDING") ? trade.ResultOrder() : 0;
               if(new_slave_ticket == 0)
               {
                   ulong deal_ticket = trade.ResultDeal();
                   if(HistoryDealSelect(deal_ticket)) new_slave_ticket = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
               }
           
               if(new_slave_ticket > 0)
               {
                   int size = ArraySize(g_master_tickets);
                   ArrayResize(g_master_tickets, size + 1);
                   ArrayResize(g_slave_tickets, size + 1);
                   g_master_tickets[size] = signal_ticket;
                   g_slave_tickets[size] = new_slave_ticket;
                   Print("✅ Copied: Master #", signal_ticket, " -> Slave #", new_slave_ticket);
               }
           }
        }
    }
    // --- بستن معامله ---
    else if(signal_action == "CLOSE_POSITION" || signal_action == "CANCEL_PENDING")
    {
        ulong slave_ticket = FindSlaveTicketByMasterTicket(signal_ticket);
        if(slave_ticket > 0)
        {
            if(PositionSelectByTicket(slave_ticket)) {
                trade.PositionClose(slave_ticket);
                Print("🔒 Closed Slave #", slave_ticket);
            }
            else if(OrderSelect(slave_ticket)) {
                trade.OrderDelete(slave_ticket);
                Print("🗑 Cancelled Slave #", slave_ticket);
            }
        }
    }
}

//+------------------------------------------------------------------+
double CalculateLotSizeByRisk(double entry_price, double sl_price)
{
   if(InpRiskPercent <= 0) return 0.0;
   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double sl_points = MathAbs(entry_price - sl_price) / _Point;
   if(sl_points <= 0) return 0.0;
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0) return 0.0;
   
   double lot_size = (risk_amount / sl_points) / (tick_value / tick_size * _Point);
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot_size = MathFloor(lot_size / volume_step) * volume_step;
   return NormalizeDouble(fmax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), fmin(lot_size, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX))), 2);
}

//+------------------------------------------------------------------+
ulong FindSlaveTicketByMasterTicket(ulong master_ticket)
{
    for(int i = 0; i < ArraySize(g_master_tickets); i++) {
        if(g_master_tickets[i] == master_ticket) {
            ulong st = g_slave_tickets[i];
            if(PositionSelectByTicket(st) || OrderSelect(st)) return st;
        }
    }
    return 0;
}

//+------------------------------------------------------------------+
string GetJsonString(string j,string k){string s="\""+k+"\":\"";int p=StringFind(j,s);if(p<0)return"";p+=StringLen(s);int e=StringFind(j,"\"",p);return e<0?"":StringSubstr(j,p,e-p);}
ulong GetJsonUlong(string j, string k){string s="\""+k+"\":";int p=StringFind(j,s);if(p<0)return 0;p+=StringLen(s);int e=StringFind(j,",",p);if(e<0)e=StringFind(j,"}",p);return e<0?0:(ulong)StringToInteger(StringSubstr(j,p,e-p));}
double GetJsonDouble(string j,string k){string s="\""+k+"\":";int p=StringFind(j,s);if(p<0)return 0.0;p+=StringLen(s);int e=StringFind(j,",",p);if(e<0)e=StringFind(j,"}",p);return e<0?0.0:StringToDouble(StringSubstr(j,p,e-p));}