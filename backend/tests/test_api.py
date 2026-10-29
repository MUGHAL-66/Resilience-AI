import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker
from sqlalchemy.pool import StaticPool
from backend.app.database import Base, get_db
from backend.app.main import app


@pytest.fixture()
def client(monkeypatch):
    engine = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    TestingSession = sessionmaker(bind=engine, autoflush=False, autocommit=False)
    Base.metadata.create_all(bind=engine)
    # Lifespan must not initialize or touch the user's on-disk server database.
    monkeypatch.setattr("backend.app.main.initialize_database", lambda: None)
    def override_db():
        db = TestingSession()
        try:
            yield db
        finally:
            db.close()
    app.dependency_overrides[get_db] = override_db
    with TestClient(app) as test_client:
        yield test_client
    app.dependency_overrides.clear()
    Base.metadata.drop_all(bind=engine)


def payload(**overrides):
    return {"client_id": "local-case-001", "injury_type": "major", "bleeding_status": "severe", "consciousness_status": "conscious", "trapped": True, "description": "Water rising", **overrides}


def test_health_and_root(client):
    assert client.get("/health").json() == {"status": "ok"}
    assert client.get("/").status_code == 200


def test_create_list_get_patch_and_idempotency(client):
    created = client.post("/emergencies", json=payload())
    assert created.status_code == 201
    case_id = created.json()["id"]
    assert client.post("/emergencies", json=payload()).json()["id"] == case_id
    assert len(client.get("/emergencies").json()) == 1
    assert client.get(f"/emergencies/{case_id}").json()["client_id"] == "local-case-001"
    updated = client.patch(f"/emergencies/{case_id}", json={"status": "resolved"})
    assert updated.status_code == 200 and updated.json()["status"] == "resolved"


def test_invalid_input_and_missing_record(client):
    assert client.post("/emergencies", json=payload(latitude=200, longitude=1)).status_code == 422
    assert client.post("/emergencies", json=payload(latitude=1)).status_code == 422
    assert client.get("/emergencies/999").status_code == 404
    assert client.patch("/emergencies/999", json={"status": "resolved"}).status_code == 404
