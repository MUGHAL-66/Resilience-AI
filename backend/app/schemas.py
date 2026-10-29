"""Validated API request and response contracts."""
from datetime import datetime
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, model_validator

Injury = Literal["none", "minor", "major", "unknown"]
Bleeding = Literal["none", "minor", "severe", "unknown"]
Consciousness = Literal["conscious", "unconscious", "unknown"]


class EmergencyCreate(BaseModel):
    client_id: str = Field(min_length=1, max_length=64, description="Stable client-generated idempotency key")
    injury_type: Injury
    bleeding_status: Bleeding
    consciousness_status: Consciousness
    trapped: bool
    description: str = Field(default="", max_length=2000)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def coordinates_pair(self):
        if (self.latitude is None) != (self.longitude is None):
            raise ValueError("latitude and longitude must both be provided or both be omitted")
        return self


class EmergencyPatch(BaseModel):
    injury_type: Injury | None = None
    bleeding_status: Bleeding | None = None
    consciousness_status: Consciousness | None = None
    trapped: bool | None = None
    description: str | None = Field(default=None, max_length=2000)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    status: Literal["open", "resolved", "cancelled"] | None = None

    @model_validator(mode="after")
    def coordinates_pair(self):
        fields = self.model_fields_set
        if ("latitude" in fields) != ("longitude" in fields):
            raise ValueError("latitude and longitude must be updated together")
        return self


class EmergencyRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)
    id: int
    client_id: str
    injury_type: str
    bleeding_status: str
    consciousness_status: str
    trapped: bool
    description: str
    latitude: float | None
    longitude: float | None
    status: str
    created_at: datetime
    updated_at: datetime
