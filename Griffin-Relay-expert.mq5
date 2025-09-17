//+------------------------------------------------------------------+
//|                                       Griffin-Relay-expert.mq5   |
//|      V2.0 - No external libraries needed (JSON parser copied)    |
//|                                                Your Name/Website |
//+------------------------------------------------------------------+
#property copyright "daedalusfx"
#property link      "https://github.com/daedalusfx"
#property version   "2.00"

#include <Trade\Trade.mqh>

// --- ورودی‌های اکسپرت
input string InpServerURL      = "http://127.0.0.1:5002/get-signals"; // آدرس سرور HTTP
input double InpRiskPercent    = 1.0;                                 // درصد ریسک برای هر معامله
input ulong  InpMagicNumber    = 17560;                                 // مجیک نامبر
input int    InpPollingInterval = 5;                                   // فاصله زمانی درخواست‌ها (به ثانیه)

// --- متغیرهای سراسری
CTrade trade;
// کتابخانه JAson حذف شد

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetMarginMode();
   EventSetTimer(InpPollingInterval);
   Print("HTTP Signal Receiver Initialized. Polling every ", InpPollingInterval, " seconds.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("HTTP Signal Receiver deinitialized.");
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   char post[], result[];
   string headers;
   int timeout = 5000;

   int res = WebRequest("GET", InpServerURL, NULL, NULL, timeout, post, 0, result, headers);
   
   if(res == 200)
   {
      string response = CharArrayToString(result);
      if(response == "[]" || response == "") return;
      
      Print("Signals received from server: ", response);
      ProcessSignals(response);
   }
   else if(res == -1)
   {
      Print("WebRequest Error: ", GetLastError());
   }
}

//+------------------------------------------------------------------+
//| پردازش سیگنال‌های دریافتی (بازنویسی شده با توابع کمکی)           |
//+------------------------------------------------------------------+
void ProcessSignals(string response)
{
   // حذف براکت‌های ابتدا و انتهای آرایه JSON
   StringTrimLeft(response);
   StringTrimRight(response);
   response = StringSubstr(response, 1, StringLen(response) - 2);

   // جدا کردن سیگنال‌های مختلف از هم
   string signals_array[];
   StringSplit(response, ',', signals_array);

   // پیمایش در سیگنال‌ها
   for(int i = 0; i < ArraySize(signals_array); i++)
   {
      string signal_json = signals_array[i];
      
      // استخراج داده‌های هر سیگنال با توابع کمکی
      string signal_action     = GetJsonString(signal_json, "action");
      ulong  signal_ticket     = GetJsonUlong(signal_json, "provider_ticket");
      string signal_symbol     = GetJsonString(signal_json, "symbol");
      int    signal_order_type = (int)GetJsonUlong(signal_json, "order_type");
      double signal_price      = GetJsonDouble(signal_json, "price");
      double signal_sl         = GetJsonDouble(signal_json, "sl");
      double signal_tp         = GetJsonDouble(signal_json, "tp");

      if(signal_symbol != _Symbol)
      {
         Print("Signal for ", signal_symbol, " ignored. EA is running on ", _Symbol);
         continue;
      }

      if(signal_action == "PLACE_PENDING" || signal_action == "OPEN_POSITION")
      {
         double lot_size = CalculateLotSizeByRisk(signal_price, signal_sl);
         if(lot_size <= 0)
         {
            Print("Could not execute trade. Invalid lot size calculated: ", lot_size);
            continue;
         }
         
         if(signal_action == "PLACE_PENDING")
            trade.OrderOpen(signal_symbol, (ENUM_ORDER_TYPE)signal_order_type, lot_size, 0, signal_price, signal_sl, signal_tp);
         else // OPEN_POSITION
         {
            if((ENUM_POSITION_TYPE)signal_order_type == POSITION_TYPE_BUY)
               trade.Buy(lot_size, signal_symbol, 0, signal_sl, signal_tp);
            else
               trade.Sell(lot_size, signal_symbol, 0, signal_sl, signal_tp);
         }
      }
      else if(signal_action == "CLOSE_POSITION")
      {
         trade.PositionClose(signal_ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| محاسبه حجم لات بر اساس درصد ریسک                                  |
//+------------------------------------------------------------------+
double CalculateLotSizeByRisk(double entry_price, double sl_price)
{
   if(InpRiskPercent <= 0) return 0.0;
   
   double account_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double risk_amount = account_balance * (InpRiskPercent / 100.0);

   double sl_points = MathAbs(entry_price - sl_price) / _Point;
   if(sl_points <= 0) return 0.0;

   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0) return 0.0;
   
   double value_per_point = tick_value / tick_size * _Point;
   double lot_size = (risk_amount / sl_points) / value_per_point;
   
   double volume_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot_size = MathFloor(lot_size / volume_step) * volume_step;
   
   double min_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   lot_size = fmax(min_volume, fmin(lot_size, max_volume));

   Print("Lot size calculated: ", lot_size, " for risk ", InpRiskPercent, "%");
   return NormalizeDouble(lot_size, 2);
}

//+------------------------------------------------------------------+
//| توابع کمکی برای پردازش JSON (کپی شده از اکسپرت اصلی)             |
//+------------------------------------------------------------------+
string GetJsonString(string json,string key){string sk="\""+key+"\":\"";int sp=StringFind(json,sk);if(sp<0)return"";sp+=StringLen(sk);int ep=StringFind(json,"\"",sp);if(ep<0)return"";return StringSubstr(json,sp,ep-sp);}
ulong GetJsonUlong(string json, string key){string sk="\""+key+"\":";int sp=StringFind(json,sk);if(sp<0)return 0;sp+=StringLen(sk);int ep=StringFind(json,",",sp);if(ep<0)ep=StringFind(json,"}",sp);if(ep<0)return 0;return(ulong)StringToInteger(StringSubstr(json,sp,ep-sp));}
double GetJsonDouble(string json,string key){string sk="\""+key+"\":";int sp=StringFind(json,sk);if(sp<0)return 0.0;sp+=StringLen(sk);int ep=StringFind(json,",",sp);if(ep<0)ep=StringFind(json,"}",sp);if(ep<0)return 0.0;return StringToDouble(StringSubstr(json,sp,ep-sp));}
bool GetJsonBool(string json,string key){string sk="\""+key+"\":";int sp=StringFind(json,sk);if(sp<0)return false;sp+=StringLen(sk);int ep=StringFind(json,",",sp);if(ep<0)ep=StringFind(json,"}",sp);if(ep<0)return false;string v=StringSubstr(json,sp,ep-sp);StringTrimRight(v);StringTrimLeft(v);return(v=="true");}