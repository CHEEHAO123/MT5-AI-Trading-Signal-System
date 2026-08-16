//+------------------------------------------------------------------+
//|  GoldMonitor.mq5  — migrated from MQL4                          |
//|  Copyright: Chee Hao                                             |
//+------------------------------------------------------------------+
#property copyright "Chee Hao"
#property version   "2.00"
#property strict

input string InpBotToken      = ""; // Telegram Bot Token
input string InpChatId        = ""; // Telegram Chat ID (live signals)
input string InpChatIdTesting = ""; // Telegram Chat ID (testing/EA-testing)
input string InpAiServerUrl   = "http://192.168.1.13:5000/analyze"; // AI analysis server URL
input bool   InpLiveMode      = true; // Enable live Telegram/AI HTTP calls (false = log only)

// ── Prevent duplicate signals ──
int lastSignalType = 0; // 1=buy, -1=sell

// ── Indicator handles (MQL5 requires handles, unlike MQL4) ──
int handleMA20_M5;
int handleSAR_M5;
int handleMACD_M5;
int handleMACD_M15;
int handleSAR_M15;
int handleMA20_M15;
int handleATR_M5;


//+------------------------------------------------------------------+
//  MarketContext — all enriched data needed for AI, loaded on demand
//+------------------------------------------------------------------+
struct MarketContext
{
    // Candles
    double curO,  curH,  curL,  curC,  curBodyPct,  curWickPct;
    double prevO, prevH, prevL, prevC, prevBodyPct, prevWickPct;
 
    // Last 50 candles summary
    int    hhhl, lhll, bigCandles, breakouts, wickRejections;
    double high50, low50;
};



//+------------------------------------------------------------------+
int OnInit()
{
    // Create indicator handles — MQL5 does not allow inline iXXX() calls on every tick  
    handleMA20_M5  = iMA  (_Symbol, PERIOD_M5,  20, 0, MODE_SMA, PRICE_CLOSE);
    handleSAR_M5   = iSAR (_Symbol, PERIOD_M5,  0.02, 0.2);
    handleMACD_M5  = iMACD(_Symbol, PERIOD_M5,  12, 26, 9, PRICE_CLOSE);
    handleMACD_M15 = iMACD(_Symbol, PERIOD_M15, 12, 26, 9, PRICE_CLOSE);
    handleSAR_M15  = iSAR (_Symbol, PERIOD_M15, 0.02, 0.2);
    handleMA20_M15 = iMA  (_Symbol, PERIOD_M15, 20, 0, MODE_SMA, PRICE_CLOSE);
    handleATR_M5   = iATR (_Symbol, PERIOD_M5,  14);

    if (handleMA20_M5  == INVALID_HANDLE ||
        handleSAR_M5   == INVALID_HANDLE ||
        handleMACD_M5  == INVALID_HANDLE ||
        handleMACD_M15 == INVALID_HANDLE ||
        handleSAR_M15  == INVALID_HANDLE)
    {
        Print("Failed to create indicator handles!");
        return INIT_FAILED;
    }

    SendTelegram("🤖 EA 分析已开始，准备起飞 ！(第二版本 MT5)");
    
    // ── Test SendToAI on startup ──
    //double testPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    //SendToAI("TEST", testPrice, true, true, true, true);
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    // Release handles to free resources
    IndicatorRelease(handleMA20_M5);
    IndicatorRelease(handleSAR_M5);
    IndicatorRelease(handleMACD_M5);
    IndicatorRelease(handleMACD_M15);
    IndicatorRelease(handleSAR_M15);
    IndicatorRelease(handleMA20_M15);
    IndicatorRelease(handleATR_M5);

    SendTelegram("🛑 EA 已被停止。(第二版本 MT5)");
}

//+------------------------------------------------------------------+
void OnTick()
{
    static datetime sarFlipTimeBull = 0;
    static datetime sarFlipTimeBear = 0;

    datetime currentCandle = iTime(_Symbol, PERIOD_M5, 0);

    // ── In MQL5, Bid is not a global — use SymbolInfoDouble() ──
    double price     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double prevClose = iClose(_Symbol, PERIOD_M5, 1);

    // ── Helper arrays — CopyBuffer() fills them (index 0 = most recent bar) ──
    double ma20Buf[1], sar1Buf[1], sar2Buf[1];
    double macdMainBuf[1], macdSigBuf[1];
    double macd15MainBuf[1], macd15SigBuf[1];
    double sar15Buf[1] , ma20_15Buf[1], atrBuf[1];

    // CopyBuffer(handle, buffer_index, start, count, array[])
    // MACD buffer 0 = MAIN line, buffer 1 = SIGNAL line (same as MQL4 MODE_MAIN/MODE_SIGNAL)
    // int  CopyBuffer(
    //   int       indicator_handle,     // indicator handle
    //   int       buffer_num,           // indicator buffer number
    //   int       start_pos,            // start position
    //   int       count,                // amount to copy
    //   double    buffer[]              // target array to copy
    // );
    if (CopyBuffer(handleMA20_M5,  0, 0,  1, ma20Buf)       < 1) return;
    if (CopyBuffer(handleSAR_M5,   0, 0,  1, sar1Buf)       < 1) return;
    if (CopyBuffer(handleSAR_M5,   0, 1,  1, sar2Buf)       < 1) return;
    if (CopyBuffer(handleMACD_M5,  0, 0,  1, macdMainBuf)   < 1) return;
    if (CopyBuffer(handleMACD_M5,  1, 0,  1, macdSigBuf)    < 1) return;
    if (CopyBuffer(handleMACD_M15, 0, 0,  1, macd15MainBuf) < 1) return;
    if (CopyBuffer(handleMACD_M15, 1, 0,  1, macd15SigBuf)  < 1) return;
    if (CopyBuffer(handleSAR_M15,  0, 0,  1, sar15Buf)      < 1) return;
    if (CopyBuffer(handleMA20_M15, 0, 0,  1, ma20_15Buf)    < 1) return;
    if (CopyBuffer(handleATR_M5,   0, 0,  1, atrBuf)        < 1) return;

    double ma20      = ma20Buf[0];
    double sar1      = sar1Buf[0];
    double sar2      = sar2Buf[0];
    double macdMain  = macdMainBuf[0];
    double macdSig   = macdSigBuf[0];
    double macd15Main = macd15MainBuf[0];
    double macd15Sig  = macd15SigBuf[0];
    double sar15      = sar15Buf[0];
    double ma20_15    = ma20_15Buf[0];
    double atr        = atrBuf[0];

    // ── Pip Size ──
    double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double pipSize = point * 10;
    double spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point;

    // ── Range Filter: 20-candle High-Low range ──
    // MQL5 iHighest/iLowest return the bar INDEX, then use iHigh/iLow with that index
    int    highestIdx = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, 20, 0);
    int    lowestIdx  = iLowest (_Symbol, PERIOD_M5, MODE_LOW,  20, 0);
    double highest    = iHigh(_Symbol, PERIOD_M5, highestIdx);
    double lowest     = iLow (_Symbol, PERIOD_M5, lowestIdx);
    double rangePips  = (highest - lowest) / pipSize;

    // ── MA Slope over 20 candles ──
    double ma20_20Buf[1];
    if (CopyBuffer(handleMA20_M5, 0, 20, 1, ma20_20Buf) < 1) return;
    double ma20_20bars = ma20_20Buf[0];
    double slopePips   = MathAbs(ma20 - ma20_20bars) / pipSize;

    // ── Sideway Label ──
    bool   isSideway    = (rangePips < 40.0) || (slopePips < 40.0);
    string sidewayLabel = isSideway ? " Sideway" : " Not Sideway";
    

    // ── SAR Flip Detection ──
    bool sarJustFlippedBullish = (sar1 < price)    && (sar2 > prevClose)
                                 && (sarFlipTimeBull != currentCandle);
    bool sarJustFlippedBearish = (sar1 > price)    && (sar2 < prevClose)
                                 && (sarFlipTimeBear != currentCandle);

    // ── M15 SAR Trend ──
    bool m15SarBull = (sar15 < price);
    bool m15SarBear = (sar15 > price);

    // ── Signal Conditions ──
    bool m5Buy  = (price > ma20) && sarJustFlippedBullish;
    bool m5Sell = (price < ma20) && sarJustFlippedBearish;

    if (!m5Buy && !m5Sell) lastSignalType = 0;

    // ── SL/TP Calculation ──
    double pipBuffer = 5 * point * 10;

    double slBuy  = sar1 - pipBuffer;
    double tpBuy  = price + (price - slBuy);
    double slSell = sar1 + pipBuffer;
    double tpSell = price - (slSell - price);

    double pipsToBuyTP  = (tpBuy  - price) / pipSize;
    double pipsToSellTP = (price  - tpSell) / pipSize;

    // ── Emoji label helpers ──
    string nl           = "%250A";
    string m5MarkBuy    = (macdMain  > macdSig)   ? "✅" : "❌";
    string m15MarkBuy   = (macd15Main > macd15Sig) ? "✅" : "❌";
    string m5MarkSell   = (macdMain  < macdSig)   ? "✅" : "❌";
    string m15MarkSell  = (macd15Main < macd15Sig) ? "✅" : "❌";
    string sar15MkBuy   = (sar15 < price)          ? "✅" : "❌";
    string sar15MkSell  = (sar15 > price)           ? "✅" : "❌";

    double minSLPoints = 10 * point * 10; // 10 pips

    // ── BUY Signal ──
    if (m5Buy && lastSignalType != 1)
    {
        double slDistancePoints = MathAbs(price - slBuy);
        if (slDistancePoints < minSLPoints)
        {
            Print("BUY blocked: SL too small = ", slDistancePoints, " points");
            return;
        }
        
        // ── Session Info ──
        string sessionLabel = GetSessionInfo();
  

        string msg = "🟢🟢🟢 BUY - GOLD"                                              + nl
                   + "Price      : "   + DoubleToString(price, 2)                     + nl
                   + "M5-MA20      :✅ "                                               + nl
                   + "M5-SAR         :✅ "                                             + nl
                   + "M5-MACD     :"   + m5MarkBuy                                    + nl
                   + "M15-SAR       :" + sar15MkBuy                                   + nl
                   + "M15-MACD   :"    + m15MarkBuy                                   + nl
                   + "Market           :" + sidewayLabel                              + nl
                   + "─────Risk TP:SL 1:1─────"                                       + nl
                   + "🛑 SL      : " + DoubleToString(slBuy,  2)
                     + " (" + DoubleToString(pipsToBuyTP,  1) + " pips）"             + nl
                   + "🎯 TP      : " + DoubleToString(tpBuy,  2)
                     + " (" + DoubleToString(pipsToBuyTP,  1) + " pips）"             + nl
                   + "───────────────────"                                             + nl
                   + "Time       :" + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + nl
                   + "Session    ：" + sessionLabel;
                   

        SendTelegram(msg);
        // ── Load enriched context only now, then send to AI ──
        MarketContext ctx;
        if (LoadMarketContext(ctx))
            SendToExtForAI(
                "BUY", price, slBuy, tpBuy, pipsToBuyTP,
                spread, atr, sidewayLabel, sessionLabel,
                ma20, sar1, macdMain, macdSig,
                ma20_15, sar15, macd15Main, macd15Sig,
                highest, lowest, ctx
        );
        lastSignalType  = 1;
        sarFlipTimeBull = currentCandle;
    }
    // ── SELL Signal ──
    else if (m5Sell && lastSignalType != -1)
    {
        double slDistancePoints = MathAbs(slSell - price);
        if (slDistancePoints < minSLPoints)
        {
            Print("SELL blocked: SL too small = ", slDistancePoints, " points");
            return;
        }
        
        // ── Session Info ──
        string sessionLabel = GetSessionInfo();

        string msg = "🔴🔴🔴 SELL - GOLD"                                             + nl
                   + "Price      : "    + DoubleToString(price, 2)                    + nl
                   + "M5-MA20      :✅ "                                               + nl
                   + "M5-SAR         :✅ "                                             + nl
                   + "M5-MACD     :"    + m5MarkSell                                  + nl
                   + "M15 SAR       :"  + sar15MkSell                                 + nl
                   + "M15-MACD   :"     + m15MarkSell                                 + nl
                   + "Market           :" + sidewayLabel                              + nl
                   + "─────Risk TP:SL 1:1─────"                                       + nl
                   + "🛑 SL     : " + DoubleToString(slSell, 2)
                     + " (" + DoubleToString(pipsToSellTP, 1) + " pips)"              + nl
                   + "🎯 TP     : " + DoubleToString(tpSell, 2)
                     + " (" + DoubleToString(pipsToSellTP, 1) + " pips)"              + nl
                   + "───────────────────"                                             + nl
                   + "Time      :" + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES)  + nl
                   + "Session   ：" + sessionLabel;
       
        SendTelegram(msg);
        // ── Load enriched context only now, then send to AI ──
       MarketContext ctx;
       if (LoadMarketContext(ctx))
            SendToExtForAI(
                "SELL", price, slSell, tpSell, pipsToSellTP,
                spread, atr, sidewayLabel, sessionLabel,
                ma20, sar1, macdMain, macdSig,
                ma20_15, sar15, macd15Main, macd15Sig,
                highest, lowest, ctx
        );
   
        lastSignalType  = -1;
        sarFlipTimeBear = currentCandle;
    }
}

//+------------------------------------------------------------------+
//  GetSessionInfo()
//  All times in MT5 server time (UTC+0 for most brokers).
//  Sessions (UTC):
//    Tokyo    : 00:00 – 09:00
//    London   : 07:00 – 16:00
//    New York : 12:00 – 21:00
//  Overlaps:
//    Tokyo/London  : 07:00 – 09:00
//    London/NY     : 12:00 – 16:00
//  Off-Hours : 21:00 – 00:00
//+------------------------------------------------------------------+
string GetSessionInfo()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;
 
    bool tokyo  = (h >= 0  && h < 9);
    bool london = (h >= 7  && h < 16);
    bool ny     = (h >= 12 && h < 21);
 
    // ── Overlaps first (most specific) ──
    if (london && ny)    return "伦敦/纽约重叠盘 (12:00-16:00 UTC) - 黄金交易最佳时间";
    if (tokyo  && london) return "东京/伦敦重叠盘 (07:00-09:00 UTC) - 黄金交易时间";
 
    // ── Single sessions ──
    if (ny)     return "纽约盘 (12:00-21:00 UTC) - 黄金交易时间";
    if (london) return "伦敦盘 (07:00-16:00 UTC) - 黄金交易时间";
    if (tokyo)  return "东京盘 (00:00-09:00 UTC) - 低波动时段， 小心交易 !";
 
    return "🌙 非交易活跃时段, 避免交易 ! ";
}


//+------------------------------------------------------------------+
bool SendTelegram(string message)
{
    // ── Backtest: print to journal instead of sending ──
    if (MQLInfoInteger(MQL_TESTER))
    {
        string printMsg = message;
        StringReplace(printMsg, "%250A", " | ");
        Print("📨 TELEGRAM: ", printMsg);
        return true;
    }

    if (!InpLiveMode)
    {
        Print("📨 TELEGRAM (live mode off): ", message);
        return true;
    }

    string url = "https://api.telegram.org/bot" + InpBotToken + "/sendMessage";
    StringReplace(message, " ", "%20");
    string fullUrl = url + "?chat_id=" + InpChatId + "&text=" + message;

    // MQL5 WebRequest signature is identical to MQL4 for the GET variant
    char   post[];
    char   result[];
    string headers;
    int res = WebRequest("GET", fullUrl, "", 5000, post, result, headers);
    if (res == 200) { Print("Telegram sent OK"); return true; }
    else            { Print("Telegram error: ", GetLastError(), " HTTP: ", res); return false; }
}

//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//  SendToExtForAI()
//  Accepts pre-loaded MarketContext struct — no data loading here.
//+------------------------------------------------------------------+
bool SendToExtForAI(
    string signal,  double price,   double sl,      double tp,    double pips,
    double spread,  double atr,     string market,  string session,
    double m5ma20,  double m5sar,   double m5macdMain,  double m5macdSig,
    double m15ma20, double m15sar,  double m15macdMain, double m15macdSig,
    double nearHigh, double nearLow,
    MarketContext &ctx
)
{
    if (MQLInfoInteger(MQL_TESTER))
    {
        Print("🤖 AI SKIP (backtest): signal=", signal, " price=", DoubleToString(price, 2));
        return true;
    }

    if (!InpLiveMode)
    {
        Print("🤖 AI SKIP (live mode off): signal=", signal, " price=", DoubleToString(price, 2));
        return true;
    }

    double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
    double range50 = ctx.high50 - ctx.low50;
    string timeStr = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);
 
    string body = "{"
        + "\"symbol\":\"XAUUSD\","
        + "\"timeframe\":\"M5\","
        + "\"time\":\""           + timeStr                           + "\","
        + "\"signal\":\""         + signal                            + "\","
        + "\"price\":"            + DoubleToString(price,    2)       + ","
        + "\"sl\":"               + DoubleToString(sl,       2)       + ","
        + "\"tp\":"               + DoubleToString(tp,       2)       + ","
        + "\"pips\":"             + DoubleToString(pips,     1)       + ","
        + "\"spread\":"           + DoubleToString(spread,   5)       + ","
        + "\"volatility\":"       + DoubleToString(atr,      5)       + ","
        + "\"market_regime\":\""  + market                            + "\","
        + "\"session\":\""        + session                           + "\","
        + "\"m5\":{"
        +   "\"ma20\":"           + DoubleToString(m5ma20,     2)     + ","
        +   "\"sar\":"            + DoubleToString(m5sar,      2)     + ","
        +   "\"macd_main\":"      + DoubleToString(m5macdMain, 6)     + ","
        +   "\"macd_sig\":"       + DoubleToString(m5macdSig,  6)     + ","
        +   "\"macd_bull\":"      + (m5macdMain > m5macdSig ? "true" : "false")
        + "},"
        + "\"m15\":{"
        +   "\"ma20\":"           + DoubleToString(m15ma20,     2)    + ","
        +   "\"sar\":"            + DoubleToString(m15sar,      2)    + ","
        +   "\"macd_main\":"      + DoubleToString(m15macdMain, 6)    + ","
        +   "\"macd_sig\":"       + DoubleToString(m15macdSig,  6)    + ","
        +   "\"macd_bull\":"      + (m15macdMain > m15macdSig ? "true" : "false")
        + "},"
        + "\"support_resistance\":{"
        +   "\"nearest_high\":"   + DoubleToString(nearHigh, 2)       + ","
        +   "\"nearest_low\":"    + DoubleToString(nearLow,  2)       + ","
        +   "\"dist_to_high\":"   + DoubleToString((nearHigh - price) / pipSize, 1) + ","
        +   "\"dist_to_low\":"    + DoubleToString((price - nearLow)  / pipSize, 1)
        + "},"
        + "\"current_candle\":{"
        +   "\"open\":"           + DoubleToString(ctx.curO,  2)      + ","
        +   "\"high\":"           + DoubleToString(ctx.curH,  2)      + ","
        +   "\"low\":"            + DoubleToString(ctx.curL,  2)      + ","
        +   "\"close\":"          + DoubleToString(ctx.curC,  2)      + ","
        +   "\"body_pct\":"       + DoubleToString(ctx.curBodyPct,  1)+ ","
        +   "\"wick_pct\":"       + DoubleToString(ctx.curWickPct,  1)
        + "},"
        + "\"previous_candle\":{"
        +   "\"open\":"           + DoubleToString(ctx.prevO, 2)      + ","
        +   "\"high\":"           + DoubleToString(ctx.prevH, 2)      + ","
        +   "\"low\":"            + DoubleToString(ctx.prevL, 2)      + ","
        +   "\"close\":"          + DoubleToString(ctx.prevC, 2)      + ","
        +   "\"body_pct\":"       + DoubleToString(ctx.prevBodyPct, 1)+ ","
        +   "\"wick_pct\":"       + DoubleToString(ctx.prevWickPct, 1)
        + "},"
        + "\"last_50_candles\":{"
        +   "\"hh_hl_count\":"    + IntegerToString(ctx.hhhl)         + ","
        +   "\"lh_ll_count\":"    + IntegerToString(ctx.lhll)         + ","
        +   "\"range_high\":"     + DoubleToString(ctx.high50,  2)    + ","
        +   "\"range_low\":"      + DoubleToString(ctx.low50,   2)    + ","
        +   "\"range_size\":"     + DoubleToString(range50,     2)    + ","
        +   "\"atr_estimate\":"   + DoubleToString(atr,         5)    + ","
        +   "\"big_candles\":"    + IntegerToString(ctx.bigCandles)   + ","
        +   "\"breakouts\":"      + IntegerToString(ctx.breakouts)    + ","
        +   "\"wick_rejections\":" + IntegerToString(ctx.wickRejections)
        + "}"
        + "}";
 
    string url        = InpAiServerUrl;
    char   post[], result[];
    string reqHeaders  = "Content-Type: application/json\r\n";
    string respHeaders;
    StringToCharArray(body, post, 0, StringLen(body));

    int res = WebRequest("POST", url, reqHeaders, 5000, post, result, respHeaders);
    if (res == 200) { Print("AI sent OK"); return true; }
    else            { Print("AI error: ", GetLastError(), " HTTP: ", res); return false; }
}
 
//+------------------------------------------------------------------+
//  LoadMarketContext()
//  Bulk-loads candle data for AI context. Call only when signal fires.
//  Returns false if data is unavailable.
//+------------------------------------------------------------------+
bool LoadMarketContext(MarketContext &ctx)
{

    // ── ATR: self-contained, no dependency on OnTick's atr variable ──
    double atrBuf[1];
    if (CopyBuffer(handleATR_M5, 0, 0, 1, atrBuf) < 1) return false;
    double atr = atrBuf[0];
 
    double highArr[], lowArr[], openArr[], closeArr[];
    ArraySetAsSeries(highArr,  true);
    ArraySetAsSeries(lowArr,   true);
    ArraySetAsSeries(openArr,  true);
    ArraySetAsSeries(closeArr, true);
 
    if (CopyHigh (_Symbol, PERIOD_M5, 0, 55, highArr)  < 55) return false;
    if (CopyLow  (_Symbol, PERIOD_M5, 0, 55, lowArr)   < 55) return false;
    if (CopyOpen (_Symbol, PERIOD_M5, 0, 55, openArr)  < 55) return false;
    if (CopyClose(_Symbol, PERIOD_M5, 0, 55, closeArr) < 55) return false;
 
    // ── Current & previous candle ──
    double price    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    ctx.curO  = openArr[0];  ctx.curH  = highArr[0];
    ctx.curL  = lowArr[0];   ctx.curC  = price;
    ctx.prevO = openArr[1];  ctx.prevH = highArr[1];
    ctx.prevL = lowArr[1];   ctx.prevC = closeArr[1];
 
    double curBody  = MathAbs(ctx.curC  - ctx.curO);
    double curRange = ctx.curH - ctx.curL;
    ctx.curBodyPct  = (curRange  > 0) ? curBody  / curRange  * 100 : 0;
    ctx.curWickPct  = (curRange  > 0) ? (curRange  - curBody)  / curRange  * 100 : 0;
 
    double prevBody  = MathAbs(ctx.prevC - ctx.prevO);
    double prevRange = ctx.prevH - ctx.prevL;
    ctx.prevBodyPct  = (prevRange > 0) ? prevBody / prevRange * 100 : 0;
    ctx.prevWickPct  = (prevRange > 0) ? (prevRange - prevBody) / prevRange * 100 : 0;
 
    // ── Last 50 candles summary ──
    ctx.hhhl = 0; ctx.lhll = 0; ctx.bigCandles = 0;
    ctx.breakouts = 0; ctx.wickRejections = 0;
    ctx.high50 = 0; ctx.low50 = DBL_MAX;
 
    for (int i = 1; i <= 49; i++)
    {
        double h  = highArr[i],   l  = lowArr[i];
        double o  = openArr[i],   c  = closeArr[i];
        double ph = highArr[i+1], pl = lowArr[i+1];
 
        if (h > ctx.high50) ctx.high50 = h;
        if (l < ctx.low50)  ctx.low50  = l;
 
        if (h > ph && l > pl) ctx.hhhl++;
        if (h < ph && l < pl) ctx.lhll++;
 
        double body      = MathAbs(c - o);
        double upperWick = h - MathMax(o, c);
        double lowerWick = MathMin(o, c) - l;
 
        if (body > atr)                                    ctx.bigCandles++;
        if (upperWick > 2*body || lowerWick > 2*body)     ctx.wickRejections++;
        if (c > highArr[i+5] || c < lowArr[i+5])          ctx.breakouts++;  // i+5 safe: copied 55 bars
    }
 
    return true;
}


//+------------------------------------------------------------------+