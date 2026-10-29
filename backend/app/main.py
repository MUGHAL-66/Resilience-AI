"""Resilience AI supplementary synchronization API."""
from contextlib import asynccontextmanager
from fastapi import Depends, FastAPI, HTTPException, status
from sqlalchemy.orm import Session
from . import schemas
from .database import get_db, initialize_database
from .repositories import emergencies


@asynccontextmanager
async def lifespan(_: FastAPI):
    initialize_database()
    yield


app = FastAPI(title="Resilience AI API", version="0.1.0", description="Optional online synchronization service; local SOS capture does not depend on this API.", lifespan=lifespan)


@app.get("/")
def root():
    return {"service": "Resilience AI API", "version": app.version, "purpose": "optional emergency synchronization"}


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/emergencies", response_model=schemas.EmergencyRead, status_code=status.HTTP_201_CREATED)
def create_emergency(payload: schemas.EmergencyCreate, db: Session = Depends(get_db)):
    # Repeating a client_id returns the existing record, making retries idempotent.
    return emergencies.create(db, payload)


@app.get("/emergencies", response_model=list[schemas.EmergencyRead])
def list_emergencies(db: Session = Depends(get_db)):
    return emergencies.list_all(db)


@app.get("/emergencies/{case_id}", response_model=schemas.EmergencyRead)
def get_emergency(case_id: int, db: Session = Depends(get_db)):
    record = emergencies.get(db, case_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Emergency not found")
    return record


@app.patch("/emergencies/{case_id}", response_model=schemas.EmergencyRead)
def patch_emergency(case_id: int, payload: schemas.EmergencyPatch, db: Session = Depends(get_db)):
    record = emergencies.get(db, case_id)
    if record is None:
        raise HTTPException(status_code=404, detail="Emergency not found")
    return emergencies.update(db, record, payload)
