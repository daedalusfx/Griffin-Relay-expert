//+------------------------------------------------------------------+
//|                                       Griffin-Relay-expert.mq5   |
//|      V3.2 - Ultra-Fast WebSocket DLL Integration + Auth Check    |
//+------------------------------------------------------------------+
#property copyright "Griffin Quant"
#property link      "https://github.com/daedalusfx"
#property version   "3.20"

#include <Trade\Trade.mqh>

// --- تعریف یک منوی کشویی برای انتخاب نوع اتصال ---
enum ENUM_CONNECTION_MODE {
    MODE_LOCAL = 0, // Local Dashboard (Port 5151)
    MODE_CLOUD = 1  // Cloud HFT Server (Port 8080)
};

// --- ایمپورت توابع DLL ---
#import "RustDllCopy\\griffin_slave_client.dll"
   bool CheckLicense(uchar &token[], uchar &api_url[]);        // تابع جدید چک لایسنس
   void InitializeService(uchar &token[], uchar &url[]);       // راه‌اندازی وب‌سوکت
   void FinalizeService();
   int  GetNextCommand(uchar& buffer[], int buffer_size);
#import

// --- ورودی‌های اکسپرت ---
input group "Authentication & Connection"
input string InpSignalToken    = "PRV-XXXXX"; // توکن سیگنال دریافتی
input string InpApiUrl         = "http://127.0.0.1:8787"; // آدرس بک‌اند Hono (لوکال یا کلادفلر)
input ENUM_CONNECTION_MODE InpConnMode = MODE_LOCAL; // نوع اتصال
input string InpCloudUrl       = "ws://127.0.0.1:8080"; // آدرس سرور ابری (در صورت انتخاب کلود)

input group "Copy Trading Settings"
input double InpRiskPercent    = 1.0;     
input ulong  InpMagicNumber    = 17560;   

input group "System Settings"
input int    InpTimerMs        = 20;

// --- متغیرهای سراسری ---
CTrade trade;
ulong g_master_tickets[]; 
ulong g_slave_tickets[];  
string g_token_filename = "Griffin_Relay_Token.txt"; // نام فایل کش

//+------------------------------------------------------------------+
//| توابع کمکی برای مدیریت کش توکن                                   |
//+------------------------------------------------------------------+
string LoadTokenCache() 
{
    if(FileIsExist(g_token_filename)) {
        int handle = FileOpen(g_token_filename, FILE_READ|FILE_TXT|FILE_ANSI);
        if(handle != INVALID_HANDLE) {
            string cached_token = FileReadString(handle);
            FileClose(handle);
            return cached_token;
        }
    }
    return "";
}

void SaveTokenCache(string token) 
{
    int handle = FileOpen(g_token_filename, FILE_WRITE|FILE_TXT|FILE_ANSI);
    if(handle != INVALID_HANDLE) {
        FileWriteString(handle, token);
        FileClose(handle);
    }
}

//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetMarginMode();
   
   string active_token = InpSignalToken;

   // ۱. مدیریت کش توکن
   if(active_token == "" || active_token == "PRV-XXXXX") {
      active_token = LoadTokenCache();
      if(active_token == "") {
         Print("❌ توکنی در کش یافت نشد! لطفا توکن سیگنال را وارد کنید.");
         return(INIT_FAILED);
      } else {
         Print("🔄 توکن با موفقیت از حافظه کش فراخوانی شد.");
      }
   } else {
      SaveTokenCache(active_token);
      Print("💾 توکن جدید در حافظه کش ذخیره شد.");
   }

   uchar token_bytes[];
   StringToCharArray(active_token, token_bytes, 0, WHOLE_ARRAY, CP_UTF8);
   
   uchar api_bytes[];
   StringToCharArray(InpApiUrl, api_bytes, 0, WHOLE_ARRAY, CP_UTF8);

   // ۲. بررسی مسدودکننده لایسنس قبل از اجرای اکسپرت
   Print("⏳ در حال بررسی اعتبار لایسنس با سرور...");
   if(!CheckLicense(token_bytes, api_bytes)) {
       Print("❌ لایسنس نامعتبر است، منقضی شده، یا سقف دستگاه‌ها پر شده است! اکسپرت روی چارت قرار نمی‌گیرد.");
       return(INIT_FAILED); // متوقف کردن اتچ شدن اکسپرت
   }
   
   Print("✅ لایسنس تایید شد. در حال اتصال به روتر وب‌سوکت...");

   // ۳. راه‌اندازی اتصال وب‌سوکت
   string target_url = (InpConnMode == MODE_LOCAL) ? "ws://127.0.0.1:5151" : InpCloudUrl;
   uchar url_bytes[];
   StringToCharArray(target_url, url_bytes, 0, WHOLE_ARRAY, CP_UTF8);

   InitializeService(token_bytes, url_bytes);
   EventSetMillisecondTimer(InpTimerMs);
   
   Print("🚀 Griffin Relay Initialized. Connecting to: ", target_url);
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
   uchar buffer[4096]; 
   
   while(true)
   {
       ArrayInitialize(buffer, 0);
       int len = GetNextCommand(buffer, 4096);
       if(len <= 0) break; 
       
       string msg = CharArrayToString(buffer, 0, len, CP_UTF8);
       
       if(StringFind(msg, "AUTH_ERROR") >= 0 || StringFind(msg, "\"status\":\"error\"") >= 0) {
           string error_msg = GetJsonString(msg, "message");
           if(error_msg == "") error_msg = msg;
           
           Print("❌ خطا در احراز هویت / اتصال روتر: ", error_msg);
           ExpertRemove(); 
           return;
       }
       
       if(StringFind(msg, "\"status\":\"success\"") >= 0) {
           Print("🟢 ", GetJsonString(msg, "message"));
           continue;
       }
       
       ProcessSingleSignal(msg);
   }
}





//+------------------------------------------------------------------+
//| پیدا کردن نام واقعی نماد در بروکر (با احتساب پسوند/پیشوند)        |
//+------------------------------------------------------------------+
string GetBrokerSymbol(string raw_symbol)
{
    // ۱. اگر نماد با همین نام دقیق وجود داشته باشد
    if(SymbolInfoInteger(raw_symbol, SYMBOL_EXIST)) return raw_symbol;

    // ۲. جستجو در تمام نمادهای بروکر برای پیدا کردن تشابه (مثلاً پیدا کردن EURUSD.m از روی EURUSD)
    int total_symbols = SymbolsTotal(false);
    for(int i = 0; i < total_symbols; i++)
    {
        string sym = SymbolName(i, false);
        if(StringFind(sym, raw_symbol) >= 0)
        {
            Print("find this");
            return sym; // نماد معادل در بروکر پیدا شد
        }
    }

    Print("not find");
 
    return raw_symbol; // در صورت عدم پیدا شدن، همان نام اولیه ارجاع داده می‌شود
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
    // string signal_symbol     = GetJsonString(json, "symbol");
    int    signal_order_type = (int)GetJsonUlong(json, "order_type");
    double signal_price      = GetJsonDouble(json, "price");
    double signal_sl         = GetJsonDouble(json, "sl");
    double signal_tp         = GetJsonDouble(json, "tp");

    // if(StringFind(_Symbol, signal_symbol) < 0) return;


    string raw_symbol = GetJsonString(json, "symbol");
    
    // 🔍 تبدیل نام نماد سیگنال به نام دقیق نماد در بروکر شما
    string signal_symbol = GetBrokerSymbol(raw_symbol);

    if(signal_action == "PLACE_PENDING" || signal_action == "OPEN_POSITION")
    {
        if(FindSlaveTicketByMasterTicket(signal_ticket) > 0) return; 
        
        // ۱. فعال‌سازی نماد در Market Watch
        if(!SymbolSelect(signal_symbol, true))
        {
            Print("❌ نماد ", signal_symbol, " (پایه: ", raw_symbol, ") در بروکر یافت نشد!");
            return;
        }

        // ۲. اطمینان از همگام‌سازی مشخصات نماد (Tick Value و Point)
        int retries = 0;
        while((SymbolInfoDouble(signal_symbol, SYMBOL_TRADE_TICK_VALUE) <= 0 || 
               SymbolInfoDouble(signal_symbol, SYMBOL_POINT) <= 0) && retries < 5)
        {
            Sleep(50); // مکث کوتاه برای دریافت مشخصات نماد از سرور بروکر
            retries++;
        }

        // ۳. بررسی تیک قیمت
        MqlTick tick;
        if(!SymbolInfoTick(signal_symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
        {
            Sleep(100);
            SymbolInfoTick(signal_symbol, tick);
        }

        // ۴. محاسبه حجم و ارسال سفارش
        double lot_size = CalculateLotSizeByRisk(signal_symbol, signal_price, signal_sl);


        if(lot_size > 0)
        {
           bool success = false;
           
           if(signal_action == "PLACE_PENDING") {
              // ثبت سفارش پندینگ روی signal_symbol
              success = trade.OrderOpen(signal_symbol, (ENUM_ORDER_TYPE)signal_order_type, lot_size, 0, signal_price, signal_sl, signal_tp, ORDER_TIME_GTC, 0, "");
           } else {
              // ثبت معامله مارکت روی signal_symbol
              if((ENUM_POSITION_TYPE)signal_order_type == POSITION_TYPE_BUY)
                 success = trade.Buy(lot_size, signal_symbol, 0, signal_sl, signal_tp);
              else
                 success = trade.Sell(lot_size, signal_symbol, 0, signal_sl, signal_tp);
           }

           // گام ۴: ثبت تیکت‌های مپ‌شده (Master -> Slave)
           if(success)
           {
               ulong new_slave_ticket = (signal_action == "PLACE_PENDING") ? trade.ResultOrder() : 0;
               if(new_slave_ticket == 0)
               {
                   ulong deal_ticket = trade.ResultDeal();
                   if(HistoryDealSelect(deal_ticket)) 
                       new_slave_ticket = HistoryDealGetInteger(deal_ticket, DEAL_POSITION_ID);
               }
           
               if(new_slave_ticket > 0)
               {
                   int size = ArraySize(g_master_tickets);
                   ArrayResize(g_master_tickets, size + 1);
                   ArrayResize(g_slave_tickets, size + 1);
                   g_master_tickets[size] = signal_ticket;
                   g_slave_tickets[size]  = new_slave_ticket;
                   Print("✅ Copied: Master #", signal_ticket, " -> Slave #", new_slave_ticket, " (", signal_symbol, ")");
               }
           }
           else
           {
               Print("❌ خطا در اجرای معامله روی ", signal_symbol, " کد خطا: ", GetLastError());
           }
        }
        else
        {
            Print("❌ محاسبه حجم لایت ناوفق بود (حجم صفر یا پارامترهای نامعتبر).");
        }
    }
    // ==========================================
    // ۲. بستن پوزیشن یا لغو سفارش پندینگ
    // ==========================================
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
    // ==========================================
    // ۳. ویرایش SL/TP پوزیشن باز
    // ==========================================
    else if(signal_action == "MODIFY_POSITION")
    {
        ulong slave_ticket = FindSlaveTicketByMasterTicket(signal_ticket);
        if(slave_ticket > 0 && PositionSelectByTicket(slave_ticket))
        {
            double new_sl = signal_sl;
            double new_tp = signal_tp;
            
            if(new_sl == 0.0) new_sl = PositionGetDouble(POSITION_SL);
            if(new_tp == 0.0) new_tp = PositionGetDouble(POSITION_TP);
            
            double sym_point = SymbolInfoDouble(signal_symbol, SYMBOL_POINT);
            if(sym_point <= 0) sym_point = _Point;
            
            if(MathAbs(new_sl - PositionGetDouble(POSITION_SL)) > sym_point * 0.1 ||
               MathAbs(new_tp - PositionGetDouble(POSITION_TP)) > sym_point * 0.1)
            {
                if(trade.PositionModify(slave_ticket, new_sl, new_tp))
                    Print("✏️ Modified Slave #", slave_ticket, " SL=", new_sl, " TP=", new_tp);
                else
                    Print("❌ Modify failed for Slave #", slave_ticket, " Error: ", GetLastError());
            }
        }
    }
    // ==========================================
    // ۴. ویرایش قیمت/SL/TP سفارش پندینگ
    // ==========================================
    else if(signal_action == "MODIFY_PENDING")
    {
        ulong slave_ticket = FindSlaveTicketByMasterTicket(signal_ticket);
        if(slave_ticket > 0 && OrderSelect(slave_ticket))
        {
            double new_price = signal_price;
            double new_sl    = signal_sl;
            double new_tp    = signal_tp;
            
            if(new_price == 0.0) new_price = OrderGetDouble(ORDER_PRICE_OPEN);
            if(new_sl == 0.0)    new_sl    = OrderGetDouble(ORDER_SL);
            if(new_tp == 0.0)    new_tp    = OrderGetDouble(ORDER_TP);
            
            if(trade.OrderModify(slave_ticket, new_price, new_sl, new_tp,
                                 (ENUM_ORDER_TYPE_TIME)OrderGetInteger(ORDER_TYPE_TIME),
                                 (datetime)OrderGetInteger(ORDER_TIME_EXPIRATION)))
                Print("✏️ Modified Pending Slave #", slave_ticket);
            else
                Print("❌ Modify Pending failed for Slave #", slave_ticket, " Error: ", GetLastError());
        }
    }
}


//+------------------------------------------------------------------+

double CalculateLotSizeByRisk(string symbol, double entry_price, double sl_price)

{
   if(InpRiskPercent <= 0) return 0.0;
   
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0) point = 0.00001;

   double risk_amount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPercent / 100.0);
   double sl_points = MathAbs(entry_price - sl_price) / point;
   
   if(sl_points <= 0) sl_points = 50.0;

   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_size <= 0) return 0.0;
   
   double lot_size = (risk_amount / sl_points) / (tick_value / tick_size * point);
   double volume_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(volume_step <= 0) volume_step = 0.01;

   lot_size = MathFloor(lot_size / volume_step) * volume_step;
   
   double min_vol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);

   return NormalizeDouble(fmax(min_vol, fmin(lot_size, max_vol)), 2);
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