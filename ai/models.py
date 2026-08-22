import os

from dotenv import load_dotenv
from sqlalchemy import (
    Boolean, Column, DateTime, DECIMAL, ForeignKey, Index, Integer, String,
    Text, create_engine, func,
)
from sqlalchemy.orm import declarative_base, relationship, sessionmaker

load_dotenv()  # loads .env into os.environ if present; no-op otherwise

DB_HOST     = os.environ.get("DB_HOST", "")
DB_PORT     = os.environ.get("DB_PORT", "3306")
DB_USER     = os.environ.get("DB_USER", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME     = os.environ.get("DB_NAME", "")

_missing = [name for name, val in (
    ("DB_HOST", DB_HOST),
    ("DB_USER", DB_USER),
    ("DB_PASSWORD", DB_PASSWORD),
    ("DB_NAME", DB_NAME),
) if not val]
if _missing:
    raise RuntimeError(f"Missing required environment variable(s): {', '.join(_missing)}")

DATABASE_URL = f"mysql+pymysql://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"

engine = create_engine(DATABASE_URL, pool_pre_ping=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)

Base = declarative_base()


class Strategy(Base):
    __tablename__ = "strategy"

    id          = Column(Integer, primary_key=True, autoincrement=True)
    version     = Column(String(50), nullable=False)
    name        = Column(String(100), nullable=False)
    description = Column(Text)
    enabled     = Column(Boolean, nullable=False, default=True)
    created_at  = Column(DateTime, nullable=False, server_default=func.now())

    signals = relationship("Signal", back_populates="strategy")


class Signal(Base):
    __tablename__ = "signal"
    __table_args__ = (
        Index("idx_signal_strategy_symbol_time", "strategy_id", "symbol", "time"),
    )

    id              = Column(Integer, primary_key=True, autoincrement=True)
    strategy_id     = Column(Integer, ForeignKey("strategy.id"), nullable=False)
    symbol          = Column(String(20), nullable=False)
    time            = Column(DateTime, nullable=False)
    signal_bar_time = Column(DateTime, nullable=False)
    session         = Column(String(30))
    type            = Column(String(10), nullable=False)
    price           = Column(DECIMAL(12, 5), nullable=False)
    sl              = Column(DECIMAL(12, 5))
    tp              = Column(DECIMAL(12, 5))
    risk_reward     = Column(DECIMAL(6, 2))
    spread          = Column(DECIMAL(10, 2))
    created_at      = Column(DateTime, nullable=False, server_default=func.now())

    strategy    = relationship("Strategy", back_populates="signals")
    indicators  = relationship("SignalIndicator", back_populates="signal")
    ai_analyses = relationship("AiAnalysis", back_populates="signal")
    outcome     = relationship("SignalOutcome", back_populates="signal", uselist=False)


class SignalIndicator(Base):
    __tablename__ = "signal_indicator"

    id        = Column(Integer, primary_key=True, autoincrement=True)
    signal_id = Column(Integer, ForeignKey("signal.id"), nullable=False, index=True)
    symbol    = Column(String(20), nullable=False)
    timeframe = Column(String(10), nullable=False)
    MA20_hit  = Column(Boolean)
    SAR_hit   = Column(Boolean)
    MACD_hit  = Column(Boolean)

    signal = relationship("Signal", back_populates="indicators")


class AiAnalysis(Base):
    __tablename__ = "ai_analysis"

    id            = Column(Integer, primary_key=True, autoincrement=True)
    signal_id     = Column(Integer, ForeignKey("signal.id"), nullable=False, index=True)
    time          = Column(DateTime, nullable=False)
    decision      = Column(String(20))
    confidence    = Column(DECIMAL(5, 2))
    risk          = Column(Text)
    comment       = Column(Text)
    raw_response  = Column(Text)

    signal = relationship("Signal", back_populates="ai_analyses")


class SignalOutcome(Base):
    __tablename__ = "signal_outcome"

    id           = Column(Integer, primary_key=True, autoincrement=True)
    signal_id    = Column(Integer, ForeignKey("signal.id"), nullable=False, unique=True)
    outcome      = Column(String(20), nullable=False)  # TP_HIT / SL_HIT / EXPIRED / OPEN
    exit_price   = Column(DECIMAL(12, 5))
    exit_time    = Column(DateTime)
    pnl_pips     = Column(DECIMAL(10, 2))
    r_multiple   = Column(DECIMAL(6, 2))
    evaluated_at = Column(DateTime)
    eval_method  = Column(String(50))

    signal = relationship("Signal", back_populates="outcome")
