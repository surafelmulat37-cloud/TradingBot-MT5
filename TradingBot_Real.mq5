//+------------------------------------------------------------------+//| TradingBot_Real.mq5                                               |//| Educational. Test on demo first. No profit guarantee.            |//+------------------------------------------------------------------+
#property copyright "Educational"
#property version   "1.30"

#include <Trade\Trade.mqh>

input double RiskPercent       = 0.20;    // lower risk for gold
input double RewardRatio       = 2.8;     // realistic reward target
input int    FastEMA           = 20;
input int    SlowEMA           = 50;
input int    StructureLookback = 40;
input int    ATRPeriod         = 14;
input double ATR_SL_Mult       = 1.8;
input int    MaxTradesPerDay   = 2;
input double MaxDailyLossPct   = 1.5;
input double MaxSpreadPoints   = 40;
input double MaxLot            = 0.05;
input int    MaxOpenPositions  = 1;
input double MinFreeMargin     = 50.0;
input int    EntryCooldownBars = 3;
input bool   TradeOnlySession  = true;
input int    SessionStartHour  = 7;       // London start
input int    SessionEndHour    = 18;      // New York close (approx)
input bool   EnableTrading     = false;   // test first on demo
input ulong  Magic             = 20251010;
input bool   EnableTelegram    = false;
input string TelegramToken     = "";
input string TelegramChatID    = "";

CTrade trade;
int fastH = INVALID_HANDLE;
int slowH = INVALID_HANDLE;
int atrH = INVALID_HANDLE;

datetime lastBar = 0;
int tradesToday = 0;
int currentDay = -1;
double dayStartBalance = 0.0;
int lastBuySignalBar = -9999;
int lastSellSignalBar = -9999;

string UrlEncode(string s)
{
   StringReplace(s, "%", "%25");
   StringReplace(s, " ", "%20");
   StringReplace(s, "\n", "%0A");
   StringReplace(s, "\r", "%0D");
   StringReplace(s, "+", "%2B");
   return s;
}

void SendTG(string text)
{
   if(!EnableTelegram || StringLen(TelegramToken) == 0 || StringLen(TelegramChatID) == 0)
      return;

   string url = "https://api.telegram.org/bot" + TelegramToken + "/sendMessage";
   string header = "Content-Type: application/x-www-form-urlencoded\r\n";
   string body = "chat_id=" + TelegramChatID + "&text=" + UrlEncode(text);

   char post[];
   char result[];
   string headers;

   int bodySize = StringToCharArray(body, post, 0, StringLen(body));
   int res = WebRequest("POST", url, header, 5000, post, bodySize, result, headers);

   if(res == -1)
      Print("Telegram error: ", GetLastError());
}

bool SessionAllowed()
{
   if(!TradeOnlySession)
      return true;

   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);

   int h = st.hour;
   return (h >= SessionStartHour && h < SessionEndHour);
}

int Trend()
{
   double f[3];
   double s[3];

   if(CopyBuffer(fastH, 0, 0, 3, f) < 3)
      return 0;
   if(CopyBuffer(slowH, 0, 0, 3, s) < 3)
      return 0;

   if(f[1] > s[1] && f[1] > f[2])
      return 1;
   if(f[1] < s[1] && f[1] < f[2])
      return -1;

   return 0;
}

bool NearSupport(double price, double buffer)
{
   int idx = iLowest(_Symbol, _Period, MODE_LOW, StructureLookback, 1);
   if(idx < 0)
      return false;

   double low = iLow(_Symbol, _Period, idx);
   return (price - low) <= buffer;
}

bool NearResistance(double price, double buffer)
{
   int idx = iHighest(_Symbol, _Period, MODE_HIGH, StructureLookback, 1);
   if(idx < 0)
      return false;

   double high = iHigh(_Symbol, _Period, idx);
   return (high - price) <= buffer;
}

bool BullishPin()
{
   double o = iOpen(_Symbol, _Period, 1);
   double c = iClose(_Symbol, _Period, 1);
   double h = iHigh(_Symbol, _Period, 1);
   double l = iLow(_Symbol, _Period, 1);

   double body = MathAbs(c - o);
   double range = h - l;
   if(range <= 0.0)
      return false;

   return (c > o) && (body <= range * 0.40) && ((MathMin(o, c) - l) >= range * 0.50);
}

bool BearishPin()
{
   double o = iOpen(_Symbol, _Period, 1);
   double c = iClose(_Symbol, _Period, 1);
   double h = iHigh(_Symbol, _Period, 1);
   double l = iLow(_Symbol, _Period, 1);

   double body = MathAbs(c - o);
   double range = h - l;
   if(range <= 0.0)
      return false;

   return (c < o) && (body <= range * 0.40) && ((h - MathMax(o, c)) >= range * 0.50);
}

double LotForRisk(double stopDistance)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * RiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue <= 0.0 || tickSize <= 0.0 || stopDistance <= 0.0)
      return 0.0;

   double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return 0.0;

   double lot = riskMoney / lossPerLot;

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   if(step > 0.0)
      lot = MathFloor(lot / step) * step;

   lot = MathMax(minL, MathMin(maxL, lot));
   if(lot > MaxLot)
      lot = MaxLot;

   return lot;
}

bool DailyLossHit()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartBalance <= 0.0)
      return false;

   double ddPct = (dayStartBalance - equity) / dayStartBalance * 100.0;
   return ddPct >= MaxDailyLossPct;
}

bool SpreadOK()
{
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread <= MaxSpreadPoints;
}

int OpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if((ulong)PositionGetInteger(POSITION_MAGIC) == Magic)
            count++;
      }
   }
   return count;
}

bool MarginOK()
{
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return freeMargin >= MinFreeMargin;
}

bool CheckCooldown(int currentBar, int lastTriggerBar)
{
   return (currentBar - lastTriggerBar) >= EntryCooldownBars;
}

int OnInit()
{
   fastH = iMA(_Symbol, _Period, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   slowH = iMA(_Symbol, _Period, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   atrH  = iATR(_Symbol, _Period, ATRPeriod);

   if(fastH == INVALID_HANDLE || slowH == INVALID_HANDLE || atrH == INVALID_HANDLE)
      return INIT_FAILED;

   trade.SetExpertMagicNumber(Magic);
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   return INIT_SUCCEEDED;
}

void TryBuy(double atrValue)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopLoss = NormalizeDouble(ask - atrValue * ATR_SL_Mult, _Digits);
   double takeProfit = NormalizeDouble(ask + (ask - stopLoss) * RewardRatio, _Digits);
   double lot = LotForRisk(ask - stopLoss);

   if(lot <= 0.0)
      return;

   if(trade.Buy(lot, _Symbol, ask, stopLoss, takeProfit, "Bot Buy"))
   {
      tradesToday++;
      lastBuySignalBar = (int)Bars(_Symbol, _Period) - 1;
      SendTG("BUY " + _Symbol + " lot=" + DoubleToString(lot, 2));
   }
}

void TrySell(double atrValue)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopLoss = NormalizeDouble(bid + atrValue * ATR_SL_Mult, _Digits);
   double takeProfit = NormalizeDouble(bid - (stopLoss - bid) * RewardRatio, _Digits);
   double lot = LotForRisk(stopLoss - bid);

   if(lot <= 0.0)
      return;

   if(trade.Sell(lot, _Symbol, bid, stopLoss, takeProfit, "Bot Sell"))
   {
      tradesToday++;
      lastSellSignalBar = (int)Bars(_Symbol, _Period) - 1;
      SendTG("SELL " + _Symbol + " lot=" + DoubleToString(lot, 2));
   }
}

void OnTick()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(dt.day != currentDay)
   {
      currentDay = dt.day;
      tradesToday = 0;
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastBuySignalBar = -9999;
      lastSellSignalBar = -9999;
   }

   datetime cur = iTime(_Symbol, _Period, 0);
   if(cur == lastBar)
      return;
   lastBar = cur;

   if(!SessionAllowed())
      return;

   int bars = Bars(_Symbol, _Period);
   if(bars < SlowEMA + 20)
      return;

   if(OpenPositions() >= MaxOpenPositions)
      return;
   if(tradesToday >= MaxTradesPerDay)
      return;
   if(DailyLossHit())
      return;
   if(!SpreadOK())
      return;
   if(!MarginOK())
      return;

   double atr[2];
   if(CopyBuffer(atrH, 0, 0, 2, atr) < 2)
      return;

   int trend = Trend();
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double buffer = atr[1];
   int currentBar = bars - 1;

   bool buySetup = (trend == 1 && NearSupport(price, buffer) && BullishPin() && CheckCooldown(currentBar, lastBuySignalBar));
   bool sellSetup = (trend == -1 && NearResistance(price, buffer) && BearishPin() && CheckCooldown(currentBar, lastSellSignalBar));

   if(buySetup)
   {
      SendTG("Signal BUY " + _Symbol + " | trend=up | atr=" + DoubleToString(atr[1], 5));
      if(EnableTrading)
         TryBuy(atr[1]);
   }
   else if(sellSetup)
   {
      SendTG("Signal SELL " + _Symbol + " | trend=down | atr=" + DoubleToString(atr[1], 5));
      if(EnableTrading)
         TrySell(atr[1]);
   }
}

void OnDeinit(const int reason)
{
   Print("EA stopped. Reason: ", reason);
}
