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



// --- متغیرهای سراسری

ulong g_master_tickets[]; // برای ذخیره تیکت‌های حساب Master
ulong g_slave_tickets[];  // برای ذخیره تیکت‌های معادل در حساب Slave

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
//| پردازش سیگنال‌های دریافتی (نسخه اصلاح شده و قابل اطمینان)           |
//+------------------------------------------------------------------+

void ProcessSignals(string response)
{
    StringTrimLeft(response);
    StringTrimRight(response);
    if(response == "[]" || response == "") return;
    response = StringSubstr(response, 1, StringLen(response) - 2);

    while(StringLen(response) > 0)
    {
        int start_pos = StringFind(response, "{");
        int end_pos = StringFind(response, "}");
        if(start_pos == -1 || end_pos == -1 || end_pos < start_pos)
        {
            break;
        }
        string signal_json = StringSubstr(response, start_pos, (end_pos - start_pos) + 1);

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
        }
        else
        {
            if(signal_action == "PLACE_PENDING" || signal_action == "OPEN_POSITION")
            {
                                // بررسی می‌کنیم که آیا برای این تیکت مستر، از قبل معامله‌ای باز یا در حال انتظار داریم؟
                if(FindSlaveTicketByMasterTicket(signal_ticket) > 0)
                {
                    Print("DUPLICATE IGNORED: A trade for master ticket ", signal_ticket, " already exists. Skipping.");
                    // به سراغ سیگنال بعدی در رشته JSON می‌رویم
                    response = StringSubstr(response, end_pos + 1);
                    continue; // حلقه while را به تکرار بعدی می‌برد
                }
                double lot_size = CalculateLotSizeByRisk(signal_price, signal_sl);
                if(lot_size <= 0)
                {
                   Print("Could not execute trade for master ticket ", signal_ticket, ". Invalid lot size.");
                }
                else
                {
                   bool success = false;
                   if(signal_action == "PLACE_PENDING")
                   {
                      success = trade.OrderOpen(signal_symbol, (ENUM_ORDER_TYPE)signal_order_type, lot_size, 0, signal_price, signal_sl, signal_tp, ORDER_TIME_GTC, 0, "");
                   }
                   else // OPEN_POSITION
                   {
                      if((ENUM_POSITION_TYPE)signal_order_type == POSITION_TYPE_BUY)
                         success = trade.Buy(lot_size, signal_symbol, 0, signal_sl, signal_tp);
                      else
                         success = trade.Sell(lot_size, signal_symbol, 0, signal_sl, signal_tp);
                   }

                   if(success)
                   {
                       ulong new_slave_ticket = 0;
                       
                       if(signal_action == "PLACE_PENDING")
                       {
                           // برای سفارشات معلق، همان تیکت سفارش درست است
                           new_slave_ticket = trade.ResultOrder();
                       }
                       else // OPEN_POSITION
                       {
                           // ۱. ابتدا تیکت Deal (رسید) را می‌گیریم
                           ulong deal_ticket = trade.ResultDeal();
                           
                           // ۲. از طریق تیکت Deal، به تیکت اصلی پوزیشن دست پیدا می‌کنیم
                           if(HistoryDealSelect(deal_ticket))
                           {
                               new_slave_ticket = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
                           }
                       }
                   
                       if(new_slave_ticket > 0)
                       {
                           int size = ArraySize(g_master_tickets);
                           ArrayResize(g_master_tickets, size + 1);
                           ArrayResize(g_slave_tickets, size + 1);
                           g_master_tickets[size] = signal_ticket;
                           g_slave_tickets[size] = new_slave_ticket;
                           Print("MAP ADDED: Master Ticket ", signal_ticket, " ==> Slave Ticket ", new_slave_ticket, " (Type: ", (signal_action == "PLACE_PENDING" ? "Order" : "Position"), ")");
                       }
                       else
                       {
                           Print("Trade executed but could not fetch slave ticket. Retcode: ", trade.ResultRetcode());
                       }
                   }
               
                  }
            }
            else if(signal_action == "CLOSE_POSITION")
            {
                ulong slave_ticket_to_close = FindSlaveTicketByMasterTicket(signal_ticket);
                if(slave_ticket_to_close > 0)
                {
                    if(PositionSelectByTicket(slave_ticket_to_close))
                    {
                        trade.PositionClose(slave_ticket_to_close);
                        Print("Closing position for master ticket ", signal_ticket, " (slave ticket: ", slave_ticket_to_close, ")");
                    }
                    else if(OrderSelect(slave_ticket_to_close))
                    {
                        trade.OrderDelete(slave_ticket_to_close);
                        Print("Deleting pending order for master ticket ", signal_ticket, " (slave ticket: ", slave_ticket_to_close, ")");
                    }
                }
                else
                {
                    Print("CLOSE IGNORED: Could not find a matching slave ticket for master ticket ", signal_ticket);
                }
            }
        }
        response = StringSubstr(response, end_pos + 1);
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


// +++  تابع برای پیدا کردن تیکت معادل در حساب Slave +++
ulong FindSlaveTicketByMasterTicket(ulong master_ticket)
{
    // حلقه برای جستجو در آرایه تیکت‌های مستر
    for(int i = 0; i < ArraySize(g_master_tickets); i++)
    {
        // اگر تیکت مستر پیدا شد
        if(g_master_tickets[i] == master_ticket)
        {
            ulong slave_ticket = g_slave_tickets[i];
            // بررسی می‌کنیم که آیا پوزیشن مربوط به این تیکت هنوز باز است یا خیر
            if(PositionSelectByTicket(slave_ticket))
            {
                // اگر باز بود، تیکت اسلیو را برمی‌گردانیم
                return slave_ticket;
            }
            // اگر یک سفارش پندینگ بود، آن را بررسی می‌کنیم
            else if(OrderSelect(slave_ticket))
            {
                 return slave_ticket;
            }
        }
    }
    // اگر هیچ تیکت معادلی پیدا نشد، صفر برمی‌گردانیم
    return 0;
}

//+------------------------------------------------------------------+
//| توابع کمکی برای پردازش JSON (کپی شده از اکسپرت اصلی)             |
//+------------------------------------------------------------------+
string GetJsonString(string json,string key){string sk="\""+key+"\":\"";int sp=StringFind(json,sk);if(sp<0)return"";sp+=StringLen(sk);int ep=StringFind(json,"\"",sp);if(ep<0)return"";return StringSubstr(json,sp,ep-sp);}
ulong GetJsonUlong(string json, string key){string sk="\""+key+"\":";int sp=StringFind(json,sk);if(sp<0)return 0;sp+=StringLen(sk);int ep=StringFind(json,",",sp);if(ep<0)ep=StringFind(json,"}",sp);if(ep<0)return 0;return(ulong)StringToInteger(StringSubstr(json,sp,ep-sp));}
double GetJsonDouble(string json,string key){string sk="\""+key+"\":";int sp=StringFind(json,sk);if(sp<0)return 0.0;sp+=StringLen(sk);int ep=StringFind(json,",",sp);if(ep<0)ep=StringFind(json,"}",sp);if(ep<0)return 0.0;return StringToDouble(StringSubstr(json,sp,ep-sp));}
bool GetJsonBool(string json,string key){string sk="\""+key+"\":";int sp=StringFind(json,sk);if(sp<0)return false;sp+=StringLen(sk);int ep=StringFind(json,",",sp);if(ep<0)ep=StringFind(json,"}",sp);if(ep<0)return false;string v=StringSubstr(json,sp,ep-sp);StringTrimRight(v);StringTrimLeft(v);return(v=="true");}