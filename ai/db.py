import logging
from contextlib import contextmanager

from ai.models import AiAnalysis, SessionLocal, Signal, SignalIndicator, SignalOutcome, Strategy

logger = logging.getLogger("db")


@contextmanager
def get_session():
    """Yield a SQLAlchemy session, committing on success and rolling back on error."""
    db = SessionLocal()
    try:
        yield db
        db.commit()
    except Exception:
        db.rollback()
        raise
    finally:
        db.close()


def get_active_strategy_id(db, name, version):
    """Look up the strategy row matching name+version. Returns None if not found."""
    row = (
        db.query(Strategy.id)
        .filter(Strategy.name == name, Strategy.version == version, Strategy.enabled.is_(True))
        .first()
    )
    return row[0] if row else None


def insert_signal(db, strategy_id, symbol, time, signal_bar_time, market_session,
                   type_, price, sl, tp, risk_reward, spread):
    row = Signal(
        strategy_id=strategy_id, symbol=symbol, time=time, signal_bar_time=signal_bar_time,
        session=market_session, type=type_, price=price, sl=sl, tp=tp,
        risk_reward=risk_reward, spread=spread,
    )
    db.add(row)
    db.flush()  # assigns row.id without ending the transaction
    return row.id


def insert_signal_indicator(db, signal_id, symbol, timeframe, ma20_hit, sar_hit, macd_hit):
    row = SignalIndicator(
        signal_id=signal_id, symbol=symbol, timeframe=timeframe,
        MA20_hit=ma20_hit, SAR_hit=sar_hit, MACD_hit=macd_hit,
    )
    db.add(row)
    db.flush()
    return row.id


def insert_ai_analysis(db, signal_id, time, decision, confidence, risk, comment, raw_response):
    row = AiAnalysis(
        signal_id=signal_id, time=time, decision=decision, confidence=confidence,
        risk=risk, comment=comment, raw_response=raw_response,
    )
    db.add(row)
    db.flush()
    return row.id


def insert_signal_outcome(db, signal_id, outcome, exit_price, exit_time,
                           pnl_pips, r_multiple, evaluated_at, eval_method):
    """Insert a signal_outcome row, or update it in place if one already exists
    for this signal_id (re-running the evaluator should overwrite, not duplicate)."""
    row = db.query(SignalOutcome).filter_by(signal_id=signal_id).first()
    if row is None:
        row = SignalOutcome(signal_id=signal_id)
        db.add(row)

    row.outcome      = outcome
    row.exit_price   = exit_price
    row.exit_time    = exit_time
    row.pnl_pips     = pnl_pips
    row.r_multiple   = r_multiple
    row.evaluated_at = evaluated_at
    row.eval_method  = eval_method

    db.flush()
    return row.id
