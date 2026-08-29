import logging
import os
from google import genai
from google.genai import errors as genai_errors
import requests
import xml.etree.ElementTree as ET
from flask import Flask, request, jsonify
from datetime import datetime, timezone, timedelta
import time as time_module

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("analyze")

app = Flask(__name__)

HTTP_TIMEOUT = 10  # seconds — applies to Telegram calls

BOT_TOKEN        = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID          = os.environ.get("TELEGRAM_CHAT_ID", "")
CHAT_ID_TESTING  = os.environ.get("TELEGRAM_CHAT_ID_TESTING", "")
GOOGLE_KEY       = os.environ.get("GEMINI_API_KEY", "")

_missing = [name for name, val in (
    ("TELEGRAM_BOT_TOKEN", BOT_TOKEN),
    ("TELEGRAM_CHAT_ID", CHAT_ID),
    ("TELEGRAM_CHAT_ID_TESTING", CHAT_ID_TESTING),
    ("GEMINI_API_KEY", GOOGLE_KEY),
) if not val]
if _missing:
    raise RuntimeError(f"Missing required environment variable(s): {', '.join(_missing)}")

client = genai.Client(api_key=GOOGLE_KEY)

 
# ════════════════════════════════════════════════════════════════════
#  NEWS CACHE  — avoids hammering ForexFactory (rate limit: 2/5 min)
# ════════════════════════════════════════════════════════════════════
_news_cache = {
    "data":        None,   # parsed list of events
    "fetched_at":  0,      # unix timestamp of last successful fetch
    "ttl_seconds": 3600,   # refresh at most once per hour
}
 
FF_XML_URL = "https://nfs.faireconomy.media/ff_calendar_thisweek.xml"
 
# Impact values we care about (case-insensitive match against FF data)
WANTED_IMPACTS   = {"high", "medium"}
WANTED_COUNTRIES = {"USD"}   # extend with "XAU" if needed
MYT = timezone(timedelta(hours=8))

def _send_telegram(chat_id, message):
    """POST a message to a Telegram chat. Never raises — logs and returns False on failure."""
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage"
    try:
        resp = requests.post(
            url, json={"chat_id": chat_id, "text": message}, timeout=HTTP_TIMEOUT
        )
        resp.raise_for_status()
        return True
    except requests.RequestException as e:
        logger.error("Telegram send failed (chat_id=%s): %s", chat_id, e)
        return False

# Send to private chat for prompt debugging
def send_telegram_private_bot(message):
    return _send_telegram(CHAT_ID_TESTING, message)

def send_telegram(message):
    return _send_telegram(CHAT_ID, message)

def call_gemini_with_retry(prompt, max_retries=3):
    """Call Gemini with exponential backoff on 429 rate limit / transient 5xx errors."""
    last_error = None

    for attempt in range(max_retries):
        try:
            response = client.models.generate_content(
                model="gemini-2.5-flash",
                contents=prompt
            )
            return response.text
        except genai_errors.ClientError as e:
            last_error = e
            if e.code == 429:
                wait = 30 * (attempt + 1)  # 30s, 60s, 90s
                logger.warning("[GEMINI] Rate limited (attempt %d/%d). Waiting %ds...",
                                attempt + 1, max_retries, wait)
                time_module.sleep(wait)
                continue
            logger.error("[GEMINI] Client error %s: %s", e.code, e.message)
            raise
        except genai_errors.ServerError as e:
            last_error = e
            wait = 10 * (attempt + 1)
            logger.warning("[GEMINI] Server error %s (attempt %d/%d). Waiting %ds...",
                            e.code, attempt + 1, max_retries, wait)
            time_module.sleep(wait)
        except Exception as e:
            logger.error("[GEMINI] Unexpected error: %s", e)
            raise

    raise RuntimeError(f"Gemini call failed after {max_retries} retries: {last_error}")
    
    
@app.route("/analyze", methods=["GET", "POST"])
def analyze():
    logger.info("REQUEST RECEIVED")
    if request.method == "GET":
        return jsonify({"status": "ok", "message": "server running"}), 200

    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        logger.warning("Rejected /analyze request with invalid or missing JSON body")
        # 200 so the EA doesn't log an HTTP failure, matching the error contract below
        return jsonify({"status": "error", "message": "invalid or missing JSON body"}), 200

    # ── Top-level fields ──
    signal     = data.get("signal",     "")
    price      = data.get("price",      "")
    time       = data.get("time",       "")
    sl         = data.get("sl",         "")
    tp         = data.get("tp",         "")
    pips       = data.get("pips",       "")
    spread     = data.get("spread",     "")
    volatility = data.get("volatility", "")
    session    = data.get("session",    "")

    # ── M5 indicators ──
    m5            = data.get("m5") or {}
    m5_ma20       = m5.get("ma20",      "")
    m5_sar        = m5.get("sar",       "")
    m5_macd_main  = m5.get("macd_main", "")
    m5_macd_sig   = m5.get("macd_sig",  "")
    m5_macd_bull  = m5.get("macd_bull", False)
    m5_macd_hist  = m5.get("macd_hist",       "")      # NEW
    m5_macd_hdir  = m5.get("macd_hist_dir",   "")      # NEW  +1.0=rising  -1.0=falling
    m5_macd_h5    = m5.get("macd_hist_last5", [])      # NEW  [oldest→current]

    # ── M15 indicators ──
    m15            = data.get("m15") or {}
    m15_ma20       = m15.get("ma20",      "")
    m15_macd_main  = m15.get("macd_main", "")
    m15_macd_sig   = m15.get("macd_sig",  "")
    m15_macd_bull  = m15.get("macd_bull", False)
    m15_macd_hist  = m15.get("macd_hist",       "")     # NEW
    m15_macd_hdir  = m15.get("macd_hist_dir",   "")     # NEW
    m15_macd_h5    = m15.get("macd_hist_last5", [])     # NEW
    m15_stoch_main = m15.get("stoch_main",      "")
    m15_stoch_sig  = m15.get("stoch_sig",       "")
    m15_stoch_trend = m15.get("stoch_trend",    "")

    # ── Support / Resistance ──
    sr                    = data.get("support_resistance") or {}
    resistance_level      = sr.get("resistance_level",          "")
    support_level         = sr.get("support_level",             "")
    resistance_touches    = sr.get("resistance_touch_count",    "")
    support_touches       = sr.get("support_touch_count",       "")
    resistance_rejections = sr.get("resistance_rejection_count","")
    support_rejections    = sr.get("support_rejection_count",   "")
    resistance_score      = sr.get("resistance_score",          "")
    support_score         = sr.get("support_score",             "")
    dist_to_resistance    = sr.get("dist_to_resistance",        "")
    dist_to_support       = sr.get("dist_to_support",           "")

    # ── Current candle ──
    cur      = data.get("current_candle") or {}
    cur_open  = cur.get("open",     "")
    cur_high  = cur.get("high",     "")
    cur_low   = cur.get("low",      "")
    cur_close = cur.get("close",    "")
    cur_body  = cur.get("body_pct", "")
    cur_wick  = cur.get("wick_pct", "")

    # ── Previous candle ──
    prev       = data.get("previous_candle") or {}
    prev_open  = prev.get("open",     "")
    prev_high  = prev.get("high",     "")
    prev_low   = prev.get("low",      "")
    prev_close = prev.get("close",    "")
    prev_body  = prev.get("body_pct", "")
    prev_wick  = prev.get("wick_pct", "")

    # ── Last 50 candles summary ──
    c50         = data.get("last_50_candles") or {}
    hh_hl       = c50.get("hh_hl_count",    "")
    lh_ll       = c50.get("lh_ll_count",    "")
    range_high  = c50.get("range_high",     "")
    range_low   = c50.get("range_low",      "")
    range_size  = c50.get("range_size",     "")
    atr_est     = c50.get("atr_estimate",   "")
    big_candles = c50.get("big_candles",    "")
    breakouts   = c50.get("breakouts",      "")
    wick_rej    = c50.get("wick_rejections","")

    m5_macd_dir  = "bullish" if m5_macd_bull  else "bearish"
    m15_macd_dir = "bullish" if m15_macd_bull else "bearish"


    # ── Format histogram last-5 as readable candle labels ──
    h5_labels = ["Candle -4", "Candle -3", "Candle -2", "Candle -1", "Current"]
    def fmt_hist5(h5):
        if not h5 or len(h5) < 5:
            return "N/A"
        return "  ".join(
            f"{h5_labels[i]}: {'+' if float(h5[i]) >= 0 else ''}{float(h5[i]):.5f}"
            for i in range(5)
        )
    m5_hist5_str  = fmt_hist5(m5_macd_h5)
    m15_hist5_str = fmt_hist5(m15_macd_h5)

    m5_hist_dir_str  = "Increasing ↑" if str(m5_macd_hdir)  == "1.0" else "Decreasing ↓"
    m15_hist_dir_str = "Increasing ↑" if str(m15_macd_hdir) == "1.0" else "Decreasing ↓"
    
    
    prompt = f"""You are a professional XAUUSD M5 scalper and institutional-style trade analyst.
    
    Your task: Analyze my EA signal and decide whether the trade should be ACCEPTED or REJECTED.

    My EA trading strategy uses:
    - Parabolic SAR for reversal timing in M5
    - MA20 for trend direction in M5
    - MACD for momentum confirmation in M5

    Rules:
      1. Do not blindly follow indicators.
      2. Prioritize market:
         - Trending market = allow continuation trades
            * HH + HL structure
            * MA20 slope clear
            * Price stays one side of MA20
            * Range expansion
         - Sideway market = avoid weak signals
            * MA20 flat
            * Price crossing MA20 frequently
            * Range size < X pips
            * No HH/HL or LH/LL structure
      3. Consider:
         - Market Regime
         - S/R Zone
         - MA20 slope
         - Price position relative to MA20
         - Gold Volatility
         - M5 Structure
         - MACD Momentum
         - M15 Alignment
         - M15 Stochastic Trend
         - SAR Timing
      4. Session:
         -London = favorable
         -New York = favorable
         -Asia = caution
         
    Symbol    : XAUUSD
    Timeframe : M5
    Time      : {time}
    Session   : {session}
    Signal    : {signal}
    Price     : {price}
    SL        : {sl}
    TP        : {tp}
    Pips      : {pips}
    Spread    : {spread}
    Volatility(ATR Period 14): {volatility}     
     
    M5 Indicators:
    - MA20          : {m5_ma20}
    - SAR           : {m5_sar}  (just flipped {signal.lower()})
    - MACD Main     : {m5_macd_main}
    - MACD Sig      : {m5_macd_sig}
    - MACD Dir      : {m5_macd_dir}
    - MACD Histogram: {m5_macd_hist}  ({m5_hist_dir_str})
    - Hist Last 5   : {m5_hist5_str}

    M15 Indicators:
    - MA20          : {m15_ma20}
    - MACD Main     : {m15_macd_main}
    - MACD Sig      : {m15_macd_sig}
    - MACD Dir      : {m15_macd_dir}
    - MACD Histogram: {m15_macd_hist}  ({m15_hist_dir_str})
    - Hist Last 5   : {m15_hist5_str}
    - Stochastic(8,3,3): Main={m15_stoch_main}  Sig={m15_stoch_sig}  ({m15_stoch_trend})

    Support / Resistance:
    - Resistance Level    : {resistance_level}  ({dist_to_resistance} pips away) 
      *Score: {resistance_score}  
      *Touches: {resistance_touches} 
      *Rejections: {resistance_rejections}
    - Support Level       : {support_level}     ({dist_to_support} pips away)    
      *Score: {support_score}    
      *Touches: {support_touches}   
      *Rejections: {support_rejections}

    Current Candle  : O={cur_open}  H={cur_high}  L={cur_low}  C={cur_close}
    - Body % : {cur_body}%   Wick % : {cur_wick}%

    Previous Candle : O={prev_open}  H={prev_high}  L={prev_low}  C={prev_close}
    - Body % : {prev_body}%   Wick % : {prev_wick}%

    Last 50 Candles Summary:
    - Trend          : HH/HL={hh_hl}  LH/LL={lh_ll}
    - Range          : High={range_high}  Low={range_low}  Size={range_size}
    - ATR est        : {atr_est}
    - Big candles    : {big_candles}
    - Breakouts      : {breakouts}
    - Wick rejections: {wick_rej}
     
    Respond in exactly this format, no extra text, but pls answer in Chinese:

    决定  : [接受 / 拒绝]
    信心  : [0-100]%
    风险  : [1句]
    评论  : [1句]"""

    try:
        send_telegram_private_bot(prompt)
        analysis = call_gemini_with_retry(prompt)
        full_msg = f"🤖 AI 分析 ({signal}) {time}\n\n{analysis}"
        send_telegram(full_msg)
        return jsonify({"status": "ok"})
    except Exception as e:
        error_msg = f"⚠️ AI 分析失败 ({signal}) — {str(e)}"
        logger.exception("[ANALYZE] failed for signal=%s", signal)
        send_telegram(error_msg)  # best-effort; _send_telegram never raises
        return jsonify({"status": "error", "message": str(e)}), 200  # return 200 so EA doesn't log HTTP error


 
def _fetch_ff_xml() -> list[dict]:
    """Download and parse the ForexFactory weekly XML calendar.
    Returns a list of event dicts filtered to USD High/Medium only.
    """
    headers = {"User-Agent": "Mozilla/5.0 (GoldMonitor EA news fetcher)"}
    resp = requests.get(FF_XML_URL, headers=headers, timeout=15)
    resp.raise_for_status()

    try:
        root = ET.fromstring(resp.content)
    except ET.ParseError as e:
        raise RuntimeError(f"ForexFactory response was not valid XML: {e}") from e

    events = []
 
    for ev in root.findall("event"):
        country = (ev.findtext("country") or "").strip().upper()
        impact  = (ev.findtext("impact")  or "").strip().lower()
 
        if country not in WANTED_COUNTRIES:
            continue
        if impact not in WANTED_IMPACTS:
            continue
 
        title    = (ev.findtext("title")    or "").strip()
        date_str = (ev.findtext("date")     or "").strip()   # e.g. 06-20-2025
        time_str = (ev.findtext("time")     or "").strip()   # e.g. 08:30am
        forecast = (ev.findtext("forecast") or "").strip()
        previous = (ev.findtext("previous") or "").strip()
 
        # ── Parse event datetime (FF uses  MM-DD-YYYY  +  hh:mmam/pm  UTC) ──
        event_dt = None
        try:
            # Some events have no time (e.g. "Tentative") — skip gracefully
            if date_str and time_str:
                dt_raw = f"{date_str} {time_str}"
                event_dt = datetime.strptime(dt_raw, "%m-%d-%Y %I:%M%p")
                event_dt = event_dt.replace(tzinfo=timezone.utc)
        except ValueError:
            pass  # keep event but without a parsed datetime
 
        events.append({
            "title":    title,
            "country":  country,
            "impact":   impact.capitalize(),
            "date":     date_str,
            "time":     time_str,
            "forecast": forecast,
            "previous": previous,
            "dt":       event_dt,        # datetime object or None
        })
 
    # Sort by event time (events without time go to the end)
    events.sort(key=lambda e: e["dt"] or datetime.max.replace(tzinfo=timezone.utc))
    return events
 
 
def get_news_cached() -> list[dict]:
    """Return cached news, refreshing if the TTL has expired."""
    now = time_module.time()
    age = now - _news_cache["fetched_at"]
 
    if _news_cache["data"] is None or age > _news_cache["ttl_seconds"]:
        logger.info("[NEWS] Cache miss (age=%.0fs) — fetching from ForexFactory…", age)
        try:
            _news_cache["data"]       = _fetch_ff_xml()
            _news_cache["fetched_at"] = now
            logger.info("[NEWS] Fetched %d USD High/Medium events.", len(_news_cache["data"]))
        except (requests.RequestException, RuntimeError) as e:
            logger.error("[NEWS] Fetch failed: %s", e)
            # Return stale data if available, empty list otherwise
            return _news_cache["data"] or []
 
    return _news_cache["data"]
 
 
def _format_news_for_telegram(events: list[dict]) -> str:
    """Build a full week USD High/Medium news summary grouped by day."""
    now_utc = datetime.now(timezone.utc)
    today = datetime.now(MYT).date()
 
    # Day-name mapping (English → Chinese)
    DAY_CN = {
        "Monday":    "周一", "Tuesday":  "周二", "Wednesday": "周三",
        "Thursday":  "周四", "Friday":   "周五", "Saturday":  "周六",
        "Sunday":    "周日",
    }
 
    # ── Group all events by date ──
    from collections import defaultdict
    by_day: dict = defaultdict(list)
    for e in events:
        if e["dt"]:
            by_day[e["dt"].date()].append(e)
        else:
            # Events with no parseable time — bucket under their date string
            try:
                d = datetime.strptime(e["date"], "%m-%d-%Y").date()
                by_day[d].append(e)
            except ValueError:
                pass  # skip completely unparseable
 
    if not by_day:
        return "📅 本周暂无 USD 高/中影响新闻。"
 
    # ── Header ──
    lines = [
        "📰 *本周 USD 重要经济新闻*",
        f"🔴 高影响  🟡 中影响  |马来西亚时间",
        "━━━━━━━━━━━━━━━━━━━━━━",
        "",
    ]
 
    for day_date in sorted(by_day.keys()):
        day_events   = by_day[day_date]
        day_name_en  = day_date.strftime("%A")
        day_name_cn  = DAY_CN.get(day_name_en, day_name_en)
        date_label   = day_date.strftime("%m/%d")
 
        # Mark today and past/future
        if day_date == datetime.now(MYT).date():
            day_header = f"📅 *{day_name_cn} {date_label}  ← 今天*"
        elif day_date < today:
            day_header = f"✅ {day_name_cn} {date_label}  (已过)"
        else:
            day_header = f"📆 *{day_name_cn} {date_label}*"
 
        lines.append(day_header)
 
        for e in day_events:
            impact_emoji = "🔴" if e["impact"].lower() == "high" else "🟡"
            time_label = "时间未定"

            if e["dt"]:
                dt_myt = e["dt"].astimezone(MYT)
                time_label = dt_myt.strftime("%H:%M")
            elif e["time"]:
                time_label = e["time"].upper()
 
            # Mark events that already passed
            passed = e["dt"] and e["dt"] < now_utc
            done   = " ~~(已发布)~~" if passed else ""
 
            # Minutes away label (only for today's future events)
            mins_label = ""
            if not passed and day_date == today and e["dt"]:
                mins = int((e["dt"] - now_utc).total_seconds() / 60)
                if mins <= 60:
                    mins_label = f"  ⏰ {mins} 分钟后"
 
            forecast_str = f"  预测:{e['forecast']}" if e["forecast"] else ""
            previous_str = f"  前值:{e['previous']}" if e["previous"] else ""
 
            lines.append(
                f"  {impact_emoji} {time_label}  {e['title']}"
                f"{forecast_str}{previous_str}{mins_label}{done}"
            )
 
        lines.append("")  # blank line between days
 
    lines += [
        "━━━━━━━━━━━━━━━━━━━━━━",
        f"_来源: ForexFactory  |  更新: {now_utc.strftime('%Y-%m-%d %H:%M')} UTC_",
    ]
 
    return "\n".join(lines)
 
 
def _format_news_for_ea(events: list[dict]) -> list[dict]:
    """Return a clean JSON-serialisable list for the EA to consume."""
    now_utc = datetime.now(timezone.utc)
    result  = []
 
    for e in events:
        # Include today + future events so the EA has context for the week
        if e["dt"] and e["dt"] < now_utc:
            continue  # already passed — skip
 
        result.append({
            "title":    e["title"],
            "impact":   e["impact"],
            "date":     e["date"],
            "time":     e["time"],
            "forecast": e["forecast"],
            "previous": e["previous"],
        })
 
    return result
 
 
# ════════════════════════════════════════════════════════════════════
#  /news  endpoint
#  GET  ?send_telegram=1   → also push to Telegram group
#  GET  (plain)            → just return JSON (for EA)
# ════════════════════════════════════════════════════════════════════
@app.route("/news", methods=["GET"])
def news():
    try:
        events = get_news_cached()
        ea_list = _format_news_for_ea(events)

        # ── Optional: push today's summary to Telegram ──
        if request.args.get("send_telegram", "0") == "1":
            msg = _format_news_for_telegram(events)
            send_telegram(msg)  # best-effort; _send_telegram never raises

        fetched_at = (
            datetime.fromtimestamp(_news_cache["fetched_at"], tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
            if _news_cache["fetched_at"] else None
        )
        return jsonify({
            "status":     "ok",
            "fetched_at": fetched_at,
            "count":      len(ea_list),
            "events":     ea_list,
        })
    except Exception as e:
        logger.exception("[NEWS] /news request failed")
        return jsonify({"status": "error", "message": str(e)}), 200


@app.errorhandler(Exception)
def handle_unexpected_error(e):
    """Last-resort net: log the full traceback and never leak a bare 500/stack trace."""
    logger.exception("Unhandled exception in %s", request.path)
    return jsonify({"status": "error", "message": "internal server error"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)