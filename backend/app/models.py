"""SQLAlchemy persistence models for the online synchronization service."""
from datetime import datetime, timezone
from sqlalchemy import Boolean, DateTime, Float, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column
from .database import Base


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


class EmergencyCase(Base):
    __tablename__ = "emergencies"
    id: Mapped[int] = mapped_column(Integer, primary_key=True, index=True)
    client_id: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    injury_type: Mapped[str] = mapped_column(String(80))
    bleeding_status: Mapped[str] = mapped_column(String(40))
    consciousness_status: Mapped[str] = mapped_column(String(40))
    trapped: Mapped[bool] = mapped_column(Boolean)
    description: Mapped[str] = mapped_column(Text, default="")
    latitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    longitude: Mapped[float | None] = mapped_column(Float, nullable=True)
    status: Mapped[str] = mapped_column(String(40), default="open")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utc_now, onupdate=utc_now)
