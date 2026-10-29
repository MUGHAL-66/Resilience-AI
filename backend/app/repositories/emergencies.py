  """Backend database access, isolated from HTTP handling."""
from sqlalchemy import select
from sqlalchemy.orm import Session
from .. import models, schemas


def create(db: Session, value: schemas.EmergencyCreate) -> models.EmergencyCase:
    existing = db.scalar(select(models.EmergencyCase).where(models.EmergencyCase.client_id == value.client_id))
    if existing:
        return existing
    record = models.EmergencyCase(**value.model_dump())
    db.add(record)
    db.commit()
    db.refresh(record)
    return record


def list_all(db: Session) -> list[models.EmergencyCase]:
    return list(db.scalars(select(models.EmergencyCase).order_by(models.EmergencyCase.created_at.desc())))


def get(db: Session, case_id: int) -> models.EmergencyCase | None:
    return db.get(models.EmergencyCase, case_id)


def update(db: Session, record: models.EmergencyCase, patch: schemas.EmergencyPatch) -> models.EmergencyCase:
    for key, value in patch.model_dump(exclude_unset=True).items():
        setattr(record, key, value)
    db.commit()
    db.refresh(record)
    return record
