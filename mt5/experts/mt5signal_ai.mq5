//+------------------------------------------------------------------+
//|  GoldMonitor (mt5signal_ai.mq5)                                  |
//|  Copyright 2026, Chee Hao                                        |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Chee Hao"
#property version   "3.00"
#property description "XAUUSD M5 signal EA: SAR flip + MA20 trend, confirmed by M15 Stochastic(8,3,3); alerts to Telegram with an AI (Gemini) second opinion."
#property strict

input string InpBotToken       = ""; // Telegram Bot Token
input string InpChatId         = ""; // Telegram Chat ID (Live Signals)
input string InpServerBaseUrl = "http://127.0.0.1:5000/"; // Analysis server URL
input bool   InpEnableNews      = true; // Enable news
input bool   InpEnableAiAnalyze = false; // Enable AI analysis

int lastSignalType = 0;

int handleMA20_M5;
int handleSAR_M5;
int handleMACD_M5;
int handleMACD_M15;
int handleMA20_M15;
int handleATR_M5;
int handleStoch_M15;

struct MarketContext
{
    double curO,  curH,  curL,  curC,  curBodyPct,  curWickPct;
    double prevO, prevH, prevL, prevC, prevBodyPct, prevWickPct;
    int    hhhl, lhll, bigCandles, breakouts, wickRejections;
    double high50, low50;
    double resistanceLevel, supportLevel;
    int    resistanceTouches, supportTouches;
    int    resistanceRejections, supportRejections;
    double resistanceScore, supportScore;
};

// ── NEW: holds everything derived from MACD histograms for a signal ──
struct MacdHistData
{
    double m5Hist;
    double m5HistDir;
    double m5Hist5[5];      // index 0 = current bar ... 4 = 4 bars ago
    double m15Hist;
    double m15HistDir;
    double m15Hist5[5];
};

//+------------------------------------------------------------------+
int OnInit()
{
    handleSAR_M5   = iSAR (_Symbol, PERIOD_M5,  0.02, 0.2);
    handleMA20_M5  = iMA  (_Symbol, PERIOD_M5,  20, 0, MODE_SMA, PRICE_CLOSE);
    handleMACD_M5  = iMACD(_Symbol, PERIOD_M5,  12, 26, 9, PRICE_CLOSE);
    handleMA20_M15 = iMA  (_Symbol, PERIOD_M15, 20, 0, MODE_SMA, PRICE_CLOSE);
    handleMACD_M15 = iMACD(_Symbol, PERIOD_M15, 12, 26, 9, PRICE_CLOSE);
    handleATR_M5   = iATR (_Symbol, PERIOD_M5,  14);
    handleStoch_M15 = iStochastic(_Symbol, PERIOD_M15, 8, 3, 3, MODE_SMA, STO_LOWHIGH);

    if (handleMA20_M5  == INVALID_HANDLE || handleSAR_M5   == INVALID_HANDLE ||
       handleMACD_M5  == INVALID_HANDLE || handleMACD_M15 == INVALID_HANDLE ||
       handleMA20_M15 == INVALID_HANDLE ||
       handleATR_M5   == INVALID_HANDLE || handleStoch_M15 == INVALID_HANDLE)
    {
        Print("Failed to create indicator handles!");
        return INIT_FAILED;
    }
    SendTelegram("🤖 EA 分析已开始，准备起飞 ！(第二版本 MT5)");
    FetchAndSendNews();
    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    IndicatorRelease(handleSAR_M5);
    IndicatorRelease(handleMACD_M5);
    IndicatorRelease(handleMACD_M15);
    IndicatorRelease(handleMA20_M5);
    IndicatorRelease(handleMA20_M15);
    IndicatorRelease(handleATR_M5);
    IndicatorRelease(handleStoch_M15);
    SendTelegram("🛑 EA 已被停止。(第二版本 MT5)");
}

//+------------------------------------------------------------------+
void OnTick()
{
    static datetime sarFlipTimeBull = 0;
    static datetime sarFlipTimeBear = 0;
    static datetime lastSignalCandle = 0;   // BUGFIX #2: blocks duplicate signal within same candle
    datetime currentCandle = iTime(_Symbol, PERIOD_M5, 0);

    double price     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double prevClose = iClose(_Symbol, PERIOD_M5, 1);

    // ── Per-tick essentials only. MACD histogram + 5-bar history is now   ──
    // ── computed on-demand inside GetMacdHistData(), called only when a  ──
    // ── signal actually fires. This removes 4x CopyBuffer(...,5,...)     ──
    // ── calls + array math from every single tick.                      ──
    double ma20Buf[1], ma20_15Buf[1];
    double sar1Buf[1], sar2Buf[1];
    double macdMainBuf[1], macdSigBuf[1];
    double macd15MainBuf[1], macd15SigBuf[1];
    double atrBuf[1];
    double stoch15MainBuf[1], stoch15SigBuf[1];

    if (CopyBuffer(handleMA20_M5,  0, 0,  1, ma20Buf)        < 1) return;
    if (CopyBuffer(handleSAR_M5,   0, 0,  1, sar1Buf)        < 1) return;
    if (CopyBuffer(handleSAR_M5,   0, 1,  1, sar2Buf)        < 1) return;
    if (CopyBuffer(handleMACD_M5,  0, 0,  1, macdMainBuf)    < 1) return;
    if (CopyBuffer(handleMACD_M5,  1, 0,  1, macdSigBuf)     < 1) return;
    if (CopyBuffer(handleMACD_M15, 0, 0,  1, macd15MainBuf)  < 1) return;
    if (CopyBuffer(handleMACD_M15, 1, 0,  1, macd15SigBuf)   < 1) return;
    if (CopyBuffer(handleMA20_M15, 0, 0,  1, ma20_15Buf)     < 1) return;
    if (CopyBuffer(handleATR_M5,   0, 0,  1, atrBuf)         < 1) return;
    if (CopyBuffer(handleStoch_M15, 0, 0, 1, stoch15MainBuf) < 1) return;
    if (CopyBuffer(handleStoch_M15, 1, 0, 1, stoch15SigBuf)  < 1) return;

    double ma20       = ma20Buf[0];
    double sar1       = sar1Buf[0];
    double sar2       = sar2Buf[0];
    double macdMain   = macdMainBuf[0];
    double macdSig    = macdSigBuf[0];
    double macd15Main = macd15MainBuf[0];
    double macd15Sig  = macd15SigBuf[0];
    double ma20_15    = ma20_15Buf[0];
    double atr        = atrBuf[0];
    double stoch15Main = stoch15MainBuf[0];
    double stoch15Sig  = stoch15SigBuf[0];

    double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double pipSize = point * 10;
    double spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point;

    int    highestIdx = iHighest(_Symbol, PERIOD_M5, MODE_HIGH, 20, 0);
    int    lowestIdx  = iLowest (_Symbol, PERIOD_M5, MODE_LOW,  20, 0);
    double highest    = iHigh(_Symbol, PERIOD_M5, highestIdx);
    double lowest     = iLow (_Symbol, PERIOD_M5, lowestIdx);
    double rangePips  = (highest - lowest) / pipSize;

    double ma20_20Buf[1];
    if (CopyBuffer(handleMA20_M5, 0, 20, 1, ma20_20Buf) < 1) return;
    double ma20_20bars = ma20_20Buf[0];
    double slopePips   = MathAbs(ma20 - ma20_20bars) / pipSize;

    bool   isSideway    = (rangePips < 40.0) || (slopePips < 40.0);
    string sidewayLabel = isSideway ? " Sideway" : " Not Sideway";

    bool sarJustFlippedBullish = (sar1 < price) && (sar2 > prevClose)
                                 && (sarFlipTimeBull != currentCandle);
    bool sarJustFlippedBearish = (sar1 > price) && (sar2 < prevClose)
                                 && (sarFlipTimeBear != currentCandle);

    bool m15StochUp   = stoch15Main > stoch15Sig;
    bool m15StochDown = stoch15Main < stoch15Sig;

    //bool m5Buy  = (price > ma20) && sarJustFlippedBullish && m15StochUp;
    //bool m5Sell = (price < ma20) && sarJustFlippedBearish && m15StochDown;
    bool m5Buy  = (price > ma20) && sarJustFlippedBullish;
    bool m5Sell = (price < ma20) && sarJustFlippedBearish;

    // BUGFIX #2: only clear lastSignalType once we've moved to a new candle.
    // Previously this reset on every tick where m5Buy/m5Sell happened to be
    // false, which let a signal re-fire on the SAME candle if price/MA
    // oscillated mid-candle (lastSignalType got zeroed, then the very next
    // true tick re-passed the "lastSignalType != 1/-1" check).
    if (!m5Buy && !m5Sell && currentCandle != lastSignalCandle)
        lastSignalType = 0;

    double pipBuffer    = 5 * point * 10;
    double slBuy        = sar1 - pipBuffer;
    double tpBuy        = price + (price - slBuy);
    double slSell       = sar1 + pipBuffer;
    double tpSell       = price - (slSell - price);
    double pipsToBuyTP  = (tpBuy  - price) / pipSize;
    double pipsToSellTP = (price  - tpSell) / pipSize;

    double minSLPoints = 10 * point * 10;

    // ── BUY Signal ──
    if (m5Buy && lastSignalType != 1)
    {
        double slDistancePoints = MathAbs(price - slBuy);
        if (slDistancePoints < minSLPoints) { Print("BUY blocked: SL too small = ", slDistancePoints); return; }

        //20260829 Chee Hao : To have pre-Message before full message
        //Goal : to notificate the user
        string prevMsg = "🟢🟢🟢 GOLD - BUY NOW \n";
        SendTelegram(prevMsg);

        string msg = BuildSignalMessage(
            true, price, slBuy, tpBuy, pipsToBuyTP,
            macdMain, macdSig, macd15Main, macd15Sig,
            stoch15Main, stoch15Sig,
            sidewayLabel
        );
        SendTelegram(msg);

        MacdHistData hist;
        GetMacdHistData(hist);

        MarketContext ctx;
        if (LoadMarketContext(ctx))
            SendToExtForAI(
                "BUY", price, slBuy, tpBuy, pipsToBuyTP,
                spread, atr, GetSessionInfoEN(),
                ma20, sar1, macdMain, macdSig, hist.m5Hist,  hist.m5HistDir,  hist.m5Hist5,
                ma20_15, macd15Main, macd15Sig, hist.m15Hist, hist.m15HistDir, hist.m15Hist5,
                stoch15Main, stoch15Sig,
                highest, lowest, ctx
            );
        lastSignalType   = 1;
        sarFlipTimeBull   = currentCandle;
        lastSignalCandle  = currentCandle;
    }
    // ── SELL Signal ──
    else if (m5Sell && lastSignalType != -1)
    {
        double slDistancePoints = MathAbs(slSell - price);
        if (slDistancePoints < minSLPoints) { Print("SELL blocked: SL too small = ", slDistancePoints); return; }

        //20260829 Chee Hao : To have pre-Message before full message
        //Goal : to notificate the user
        string prevMsg = "🔴🔴🔴 GOLD - SELL NOW \n";
        SendTelegram(prevMsg);

        string msg = BuildSignalMessage(
            false, price, slSell, tpSell, pipsToSellTP,
            macdMain, macdSig, macd15Main, macd15Sig,
            stoch15Main, stoch15Sig,
            sidewayLabel
        );
        SendTelegram(msg);

        MacdHistData hist;
        GetMacdHistData(hist);

        MarketContext ctx;
        if (LoadMarketContext(ctx))
            SendToExtForAI(
                "SELL", price, slSell, tpSell, pipsToSellTP,
                spread, atr, GetSessionInfoEN(),
                ma20, sar1, macdMain, macdSig, hist.m5Hist,  hist.m5HistDir,  hist.m5Hist5,
                ma20_15, macd15Main, macd15Sig, hist.m15Hist, hist.m15HistDir, hist.m15Hist5,
                stoch15Main, stoch15Sig,
                highest, lowest, ctx
            );
        lastSignalType   = -1;
        sarFlipTimeBear   = currentCandle;
        lastSignalCandle  = currentCandle;
    }
}

//+------------------------------------------------------------------+
//  GetMacdHistData()
//  Computes the MACD histogram (main-signal) for the current bar and
//  the previous 4 bars, for both M5 and M15, plus the direction flag.
//  Only called when a BUY/SELL signal actually fires — moved out of
//  the per-tick hot path.
//+------------------------------------------------------------------+
bool GetMacdHistData(MacdHistData &out)
{
    double macdMain5[5],  macdSig5[5];
    double macd15Main5[5], macd15Sig5[5];

    if (CopyBuffer(handleMACD_M5,  0, 0, 5, macdMain5)   < 5) return false;
    if (CopyBuffer(handleMACD_M5,  1, 0, 5, macdSig5)    < 5) return false;
    if (CopyBuffer(handleMACD_M15, 0, 0, 5, macd15Main5) < 5) return false;
    if (CopyBuffer(handleMACD_M15, 1, 0, 5, macd15Sig5)  < 5) return false;

    for (int i = 0; i < 5; i++)
    {
        out.m5Hist5[i]  = macdMain5[i]   - macdSig5[i];
        out.m15Hist5[i] = macd15Main5[i] - macd15Sig5[i];
    }

    out.m5Hist      = out.m5Hist5[0];
    out.m15Hist     = out.m15Hist5[0];
    out.m5HistDir   = (out.m5Hist5[0]  > out.m5Hist5[1])  ? 1.0 : -1.0;
    out.m15HistDir  = (out.m15Hist5[0] > out.m15Hist5[1]) ? 1.0 : -1.0;

    return true;
}

//+------------------------------------------------------------------+
//  BuildSignalMessage()
//  Builds the Telegram message body for a BUY or SELL signal.
//  Pulled out of OnTick so message formatting only happens when a
//  signal actually fires, and so BUY/SELL share one implementation.
//+------------------------------------------------------------------+
string BuildSignalMessage(
    bool   isBuy,
    double price , double sl, double tp, double pips,
    double macdMain, double macdSig,
    double macd15Main, double macd15Sig,
    double stoch15Main, double stoch15Sig,
    string sidewayLabel
)
{
    string nl   = "\n";
    string chkY = "✅";
    string chkN = "❌";

    string m5Mark   = isBuy ? ((macdMain   > macdSig)   ? chkY : chkN)
                             : ((macdMain   < macdSig)   ? chkY : chkN);
    string m15Mark  = isBuy ? ((macd15Main > macd15Sig) ? chkY : chkN)
                             : ((macd15Main < macd15Sig) ? chkY : chkN);

    // Stochastic(8,3,3): %K (main) above %D (signal) = uptrend, below = downtrend
    string m15StochMark  = isBuy ? ((stoch15Main > stoch15Sig) ? chkY : chkN)
                                      : ((stoch15Main < stoch15Sig) ? chkY : chkN);

    string sessionLabel = GetSessionInfo();
    string header   = isBuy ? "🟢🟢🟢 BUY - GOLD" : "🔴🔴🔴 SELL - GOLD";
    string slLine    = isBuy ? "🛑 SL      : " : "🛑 SL     : ";
    string tpLine    = isBuy ? "🎯 TP      : " : "🎯 TP     : ";

    string msg = header                                                       + nl
               + "Price      : "  + DoubleToString(price, 2)                   + nl
               + "M5-MA20      :" + chkY                                       + nl
               + "M5-SAR         :" + chkY                                     + nl
               + "M5-MACD     :"  + m5Mark                                     + nl
               + "M15-Stoch   :" + m15StochMark                              + nl
               + "M15-MACD   :"   + m15Mark                                    + nl
               + "Market           :" + sidewayLabel                          + nl
               + "─────Risk TP:SL 1:1─────"                                    + nl
               + slLine + DoubleToString(sl, 2) + " (" + DoubleToString(pips, 1) + " pips）" + nl
               + tpLine + DoubleToString(tp, 2) + " (" + DoubleToString(pips, 1) + " pips）" + nl
               + "───────────────────"                                          + nl
               + "Time       :" + TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES) + nl
               + "Session    ：" + sessionLabel;

    return msg;
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
    if (MQLInfoInteger(MQL_TESTER))
    {
        string printMsg = message;
        StringReplace(printMsg, "\n", " | ");
        Print("📨 TELEGRAM: ", printMsg);
        return true;
    }

    string url = "https://api.telegram.org/bot" + InpBotToken + "/sendMessage";

    // Build JSON body instead of URL-encoded GET
    string jsonBody = "{\"chat_id\":\"" + InpChatId + "\","
                    + "\"text\":\""     + EscapeJson(message) + "\"}";

    char   post[];
    char   result[];
    string reqHeaders  = "Content-Type: application/json\r\n";
    string respHeaders;
    int len = StringToCharArray(jsonBody, post, 0, StringLen(jsonBody), CP_UTF8);
    ArrayResize(post, len - 1);  // remove null terminator

    int res = WebRequest("POST", url, reqHeaders, 5000, post, result, respHeaders);
    if (res == 200) { Print("Telegram sent OK"); return true; }
    else            { Print("Telegram error: ", GetLastError(), " HTTP: ", res,
                            " Body: ", CharArrayToString(result)); return false; }
}

string EscapeJson(const string text)
{
    string result = text;
    StringReplace(result, "\\", "\\\\");  // backslash first
    StringReplace(result, "\"", "\\\"");  // quotes
    StringReplace(result, "\n", "\\n");   // newlines
    StringReplace(result, "\r", "\\r");   // carriage returns
    StringReplace(result, "\t", "\\t");   // tabs
    return result;
}

//+------------------------------------------------------------------+
//  SendToExtForAI()
//  Accepts pre-loaded MarketContext struct — no data loading here.
//+------------------------------------------------------------------+
bool SendToExtForAI(
    string signal,  double price,   double sl,       double tp,     double pips,
    double spread,  double atr,     string session,
    double m5ma20,  double m5sar,   double m5macdMain,  double m5macdSig,
    double m5macdHist,  double m5macdHistDir,  double &m5Hist5[],
    double m15ma20, double m15macdMain, double m15macdSig,
    double m15macdHist, double m15macdHistDir, double &m15Hist5[],
    double m15stochMain, double m15stochSig,
    double nearHigh, double nearLow,
    MarketContext &ctx
)
{
    if (MQLInfoInteger(MQL_TESTER))
    {
        Print("🤖 AI SKIP (backtest): signal=", signal, " price=", DoubleToString(price, 2));
        return true;
    }

    if (!InpEnableAiAnalyze)
    {
        Print("🤖 AI SKIP (AI analyze disabled): signal=", signal, " price=", DoubleToString(price, 2));
        return true;
    }

    double pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;
    double range50 = ctx.high50 - ctx.low50;
    string timeStr = TimeToString(TimeCurrent(), TIME_DATE|TIME_MINUTES);

    // Build M5 histogram history JSON array
    // m5Hist5[0]=current, [1]=prev1, [2]=prev2, [3]=prev3, [4]=prev4
    string m5HistArr = "["
        + DoubleToString(m5Hist5[4], 5) + ","   // candle -4 (oldest)
        + DoubleToString(m5Hist5[3], 5) + ","   // candle -3
        + DoubleToString(m5Hist5[2], 5) + ","   // candle -2
        + DoubleToString(m5Hist5[1], 5) + ","   // candle -1
        + DoubleToString(m5Hist5[0], 5)          // current
        + "]";

    string m15HistArr = "["
        + DoubleToString(m15Hist5[4], 5) + ","
        + DoubleToString(m15Hist5[3], 5) + ","
        + DoubleToString(m15Hist5[2], 5) + ","
        + DoubleToString(m15Hist5[1], 5) + ","
        + DoubleToString(m15Hist5[0], 5)
        + "]";

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
        + "\"session\":\""        + session                           + "\","
        + "\"m5\":{"
        +   "\"ma20\":"           + DoubleToString(m5ma20,      2)    + ","
        +   "\"sar\":"            + DoubleToString(m5sar,       2)    + ","
        +   "\"macd_main\":"      + DoubleToString(m5macdMain,  6)    + ","
        +   "\"macd_sig\":"       + DoubleToString(m5macdSig,   6)    + ","
        +   "\"macd_bull\":"      + (m5macdMain > m5macdSig ? "true" : "false") + ","
        +   "\"macd_hist\":"      + DoubleToString(m5macdHist,  6)    + ","
        +   "\"macd_hist_dir\":"  + DoubleToString(m5macdHistDir, 1)  + ","
        +   "\"macd_hist_last5\":" + m5HistArr
        + "},"
        + "\"m15\":{"
        +   "\"ma20\":"           + DoubleToString(m15ma20,     2)    + ","
        +   "\"macd_main\":"      + DoubleToString(m15macdMain, 6)    + ","
        +   "\"macd_sig\":"       + DoubleToString(m15macdSig,  6)    + ","
        +   "\"macd_bull\":"      + (m15macdMain > m15macdSig ? "true" : "false") + ","
        +   "\"macd_hist\":"      + DoubleToString(m15macdHist, 6)    + ","
        +   "\"macd_hist_dir\":"  + DoubleToString(m15macdHistDir, 1) + ","
        +   "\"macd_hist_last5\":" + m15HistArr                       + ","
        +   "\"stoch_main\":"     + DoubleToString(m15stochMain, 2)   + ","
        +   "\"stoch_sig\":"      + DoubleToString(m15stochSig,  2)   + ","
        +   "\"stoch_trend\":\"" + (m15stochMain > m15stochSig ? "Uptrend" : "Downtrend") + "\""
        + "},"
        + "\"support_resistance\":{"
        +   "\"resistance_level\":"         + DoubleToString(ctx.resistanceLevel, 2)  + ","
        +   "\"support_level\":"            + DoubleToString(ctx.supportLevel,    2)  + ","
        +   "\"resistance_touch_count\":"   + IntegerToString(ctx.resistanceTouches)  + ","
        +   "\"support_touch_count\":"      + IntegerToString(ctx.supportTouches)     + ","
        +   "\"resistance_rejection_count\":" + IntegerToString(ctx.resistanceRejections) + ","
        +   "\"support_rejection_count\":"  + IntegerToString(ctx.supportRejections)  + ","
        +   "\"resistance_score\":"         + DoubleToString(ctx.resistanceScore, 1)  + ","
        +   "\"support_score\":"            + DoubleToString(ctx.supportScore,    1)  + ","
        +   "\"dist_to_resistance\":"       + DoubleToString((ctx.resistanceLevel - price) / pipSize, 1) + ","
        +   "\"dist_to_support\":"          + DoubleToString((price - ctx.supportLevel)    / pipSize, 1)
        + "},"
        + "\"current_candle\":{"
        +   "\"open\":"     + DoubleToString(ctx.curO,       2) + ","
        +   "\"high\":"     + DoubleToString(ctx.curH,       2) + ","
        +   "\"low\":"      + DoubleToString(ctx.curL,       2) + ","
        +   "\"close\":"    + DoubleToString(ctx.curC,       2) + ","
        +   "\"body_pct\":" + DoubleToString(ctx.curBodyPct, 1) + ","
        +   "\"wick_pct\":" + DoubleToString(ctx.curWickPct, 1)
        + "},"
        + "\"previous_candle\":{"
        +   "\"open\":"     + DoubleToString(ctx.prevO,       2) + ","
        +   "\"high\":"     + DoubleToString(ctx.prevH,       2) + ","
        +   "\"low\":"      + DoubleToString(ctx.prevL,       2) + ","
        +   "\"close\":"    + DoubleToString(ctx.prevC,       2) + ","
        +   "\"body_pct\":" + DoubleToString(ctx.prevBodyPct, 1) + ","
        +   "\"wick_pct\":" + DoubleToString(ctx.prevWickPct, 1)
        + "},"
        + "\"last_50_candles\":{"
        +   "\"hh_hl_count\":"     + IntegerToString(ctx.hhhl)       + ","
        +   "\"lh_ll_count\":"     + IntegerToString(ctx.lhll)       + ","
        +   "\"range_high\":"      + DoubleToString(ctx.high50,  2)  + ","
        +   "\"range_low\":"       + DoubleToString(ctx.low50,   2)  + ","
        +   "\"range_size\":"      + DoubleToString(range50,     2)  + ","
        +   "\"atr_estimate\":"    + DoubleToString(atr,         5)  + ","
        +   "\"big_candles\":"     + IntegerToString(ctx.bigCandles) + ","
        +   "\"breakouts\":"       + IntegerToString(ctx.breakouts)  + ","
        +   "\"wick_rejections\":" + IntegerToString(ctx.wickRejections)
        + "}"
        + "}";

    string url        = InpServerBaseUrl + "analyze";
    char   post[], result[];
    string reqHeaders  = "Content-Type: application/json\r\n";
    string respHeaders;
    StringToCharArray(body, post, 0, StringLen(body), CP_UTF8);

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

   if (CopyHigh (_Symbol, PERIOD_M5, 0, 75, highArr)  < 75) return false;
   if (CopyLow  (_Symbol, PERIOD_M5, 0, 75, lowArr)   < 75) return false;
   if (CopyOpen (_Symbol, PERIOD_M5, 0, 75, openArr)  < 75) return false;
   if (CopyClose(_Symbol, PERIOD_M5, 0, 75, closeArr) < 75) return false;

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
    ctx.resistanceTouches = 0;  ctx.supportTouches = 0;
    ctx.resistanceRejections = 0;  ctx.supportRejections = 0;

    // NOTE: this loop reads up to highArr[i+20] / lowArr[i+20]. With i maxing
    // out at 49, the highest index touched is 69 — within the 75-bar arrays
    // loaded above. If the CopyHigh/Low/Open/Close bar count above is ever
    // reduced below 70, this inner loop must be bounds-checked or it will
    // read past the end of the array.
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

        double highest20 = highArr[i+1];  double lowest20  = lowArr[i+1];
        for(int j = 1; j <= 20; j++)
        {
            if(highArr[i+j] > highest20)
                highest20 = highArr[i+j];

            if(lowArr[i+j] < lowest20)
                lowest20 = lowArr[i+j];
        }

        // Breakout requires:
        // 1. Break 20 candle high/low
        // 2. Strong candle body > ATR
        if((c > highest20 && body > atr) || (c < lowest20 && body > atr))
        {
            ctx.breakouts++;
        }
    }


    // ======================================
    // Support Resistance Strength Analysis
    // ======================================
    ctx.resistanceLevel = ctx.high50;
    ctx.supportLevel = ctx.low50;
    double tolerance = atr * 0.5;


    // Scan last 50 candles
    for(int i = 1; i <= 49; i++)
    {
       double high = highArr[i];
       double low  = lowArr[i];
       double open = openArr[i];
       double close = closeArr[i];


       // -------------------------
       // Resistance test
       // -------------------------
       if(MathAbs(high - ctx.resistanceLevel) <= tolerance)
       {
           ctx.resistanceTouches++;

           double upperWick =
           high - MathMax(open,close);

           double body =
           MathAbs(close-open);

           if(upperWick > body*2)
               ctx.resistanceRejections++;
       }

       // -------------------------
       // Support test
       // -------------------------

       if(MathAbs(low - ctx.supportLevel) <= tolerance)
       {
           ctx.supportTouches++;
           double lowerWick = MathMin(open,close)-low;
           double body = MathAbs(close-open);

           if(lowerWick > body*2)
               ctx.supportRejections++;
       }

    }

    // Score calculation
    ctx.resistanceScore =(ctx.resistanceTouches * 2 + ctx.resistanceRejections * 3);
    ctx.supportScore =( ctx.supportTouches * 2 + ctx.supportRejections * 3);
    return true;

}


//+------------------------------------------------------------------+
//  FetchAndSendNews()
//  Hits the Flask /news?send_telegram=1 endpoint.
//  Flask handles the ForexFactory fetch, filtering, caching,
//  and pushing the formatted message to the Telegram group.
//  The EA only needs to fire the GET and check the HTTP status.
//+------------------------------------------------------------------+
bool FetchAndSendNews()
{
    if (MQLInfoInteger(MQL_TESTER))
    {
        Print("📰 NEWS SKIP (backtest mode)");
        return true;
    }

    if (!InpEnableNews)
    {
        Print("📰 NEWS SKIP (news disabled)");
        return true;
    }

    // ?send_telegram=1  tells Flask to also push the summary to Telegram
    string url = InpServerBaseUrl + "news?send_telegram=1";

    char   post[];
    char   result[];
    string respHeaders;

    int res = WebRequest("GET", url, "", 8000, post, result, respHeaders);

    if (res == 200)
    {
        Print("📰 News fetched and sent to Telegram OK");
        return true;
    }
    else
    {
        Print("📰 News fetch failed. HTTP=", res, "  Error=", GetLastError());
        return false;
    }
}

//+------------------------------------------------------------------+
//  GetSessionInfoEN()
//  English version of GetSessionInfo() — used for the AI JSON payload
//  so the external Python/AI service receives session info in English
//  instead of Chinese. Same UTC session boundaries as GetSessionInfo().
//+------------------------------------------------------------------+
string GetSessionInfoEN()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    int h = dt.hour;

    bool tokyo  = (h >= 0  && h < 9);
    bool london = (h >= 7  && h < 16);
    bool ny     = (h >= 12 && h < 21);

    // ── Overlaps first (most specific) ──
    if (london && ny)     return "London/New York Overlap (12:00-16:00 UTC)";
    if (tokyo  && london) return "Tokyo/London Overlap (07:00-09:00 UTC)";

    // ── Single sessions ──
    if (ny)     return "New York Session (12:00-21:00 UTC)";
    if (london) return "London Session (07:00-16:00 UTC)";
    if (tokyo)  return "Tokyo Session (00:00-09:00 UTC)";

    return "Off-Hours - Avoid trading!";
}
