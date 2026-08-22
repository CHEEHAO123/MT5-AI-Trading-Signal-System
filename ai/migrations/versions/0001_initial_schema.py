"""initial schema: strategy, signal, signal_indicator, ai_analysis, signal_outcome

Revision ID: 0001
Revises:
Create Date: 2026-08-22

"""
from alembic import op
import sqlalchemy as sa

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "strategy",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("version", sa.String(50), nullable=False),
        sa.Column("name", sa.String(100), nullable=False),
        sa.Column("description", sa.Text),
        sa.Column("enabled", sa.Boolean, nullable=False, server_default=sa.true()),
        sa.Column("created_at", sa.DateTime, nullable=False, server_default=sa.func.now()),
        mysql_engine="InnoDB",
    )

    op.create_table(
        "signal",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("strategy_id", sa.Integer, sa.ForeignKey("strategy.id"), nullable=False),
        sa.Column("symbol", sa.String(20), nullable=False),
        sa.Column("time", sa.DateTime, nullable=False),
        sa.Column("signal_bar_time", sa.DateTime, nullable=False),
        sa.Column("session", sa.String(30)),
        sa.Column("type", sa.String(10), nullable=False),
        sa.Column("price", sa.DECIMAL(12, 5), nullable=False),
        sa.Column("sl", sa.DECIMAL(12, 5)),
        sa.Column("tp", sa.DECIMAL(12, 5)),
        sa.Column("risk_reward", sa.DECIMAL(6, 2)),
        sa.Column("spread", sa.DECIMAL(10, 2)),
        sa.Column("created_at", sa.DateTime, nullable=False, server_default=sa.func.now()),
        mysql_engine="InnoDB",
    )
    op.create_index("idx_signal_strategy_symbol_time", "signal", ["strategy_id", "symbol", "time"])

    op.create_table(
        "signal_indicator",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("signal_id", sa.Integer, sa.ForeignKey("signal.id"), nullable=False),
        sa.Column("symbol", sa.String(20), nullable=False),
        sa.Column("timeframe", sa.String(10), nullable=False),
        sa.Column("MA20_hit", sa.Boolean),
        sa.Column("SAR_hit", sa.Boolean),
        sa.Column("MACD_hit", sa.Boolean),
        mysql_engine="InnoDB",
    )
    op.create_index("idx_signal_indicator_signal", "signal_indicator", ["signal_id"])

    op.create_table(
        "ai_analysis",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("signal_id", sa.Integer, sa.ForeignKey("signal.id"), nullable=False),
        sa.Column("time", sa.DateTime, nullable=False),
        sa.Column("decision", sa.String(20)),
        sa.Column("confidence", sa.DECIMAL(5, 2)),
        sa.Column("risk", sa.Text),
        sa.Column("comment", sa.Text),
        sa.Column("raw_response", sa.Text),
        mysql_engine="InnoDB",
    )
    op.create_index("idx_ai_analysis_signal", "ai_analysis", ["signal_id"])

    op.create_table(
        "signal_outcome",
        sa.Column("id", sa.Integer, primary_key=True, autoincrement=True),
        sa.Column("signal_id", sa.Integer, sa.ForeignKey("signal.id"), nullable=False, unique=True),
        sa.Column("outcome", sa.String(20), nullable=False),
        sa.Column("exit_price", sa.DECIMAL(12, 5)),
        sa.Column("exit_time", sa.DateTime),
        sa.Column("pnl_pips", sa.DECIMAL(10, 2)),
        sa.Column("r_multiple", sa.DECIMAL(6, 2)),
        sa.Column("evaluated_at", sa.DateTime),
        sa.Column("eval_method", sa.String(50)),
        mysql_engine="InnoDB",
    )

    # Seed row for the existing GoldMonitor EA (mt5/experts/mt5signal_ai.mq5,
    # #property version "2.10") so signal.strategy_id has something to point at.
    strategy_table = sa.table(
        "strategy",
        sa.column("version", sa.String),
        sa.column("name", sa.String),
        sa.column("description", sa.String),
        sa.column("enabled", sa.Boolean),
    )
    op.bulk_insert(
        strategy_table,
        [{
            "version": "2.10",
            "name": "GoldMonitor",
            "description": "XAUUSD M5 SAR flip + MA20 trend + MACD confirmation EA",
            "enabled": True,
        }],
    )


def downgrade():
    op.drop_table("signal_outcome")
    op.drop_table("ai_analysis")
    op.drop_table("signal_indicator")
    op.drop_index("idx_signal_strategy_symbol_time", table_name="signal")
    op.drop_table("signal")
    op.drop_table("strategy")
