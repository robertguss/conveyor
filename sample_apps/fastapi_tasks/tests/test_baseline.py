import pytest
from httpx import ASGITransport, AsyncClient

from fastapi_tasks.app import create_app


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.mark.anyio
async def test_healthz_reports_ok() -> None:
    async with AsyncClient(
        transport=ASGITransport(app=create_app()),
        base_url="http://testserver",
    ) as client:
        response = await client.get("/healthz")

        assert response.status_code == 200
        assert response.json() == {"status": "ok"}


@pytest.mark.anyio
async def test_tasks_start_empty() -> None:
    async with AsyncClient(
        transport=ASGITransport(app=create_app()),
        base_url="http://testserver",
    ) as client:
        response = await client.get("/tasks")

        assert response.status_code == 200
        assert response.json() == []


@pytest.mark.anyio
async def test_create_task_then_list_tasks() -> None:
    async with AsyncClient(
        transport=ASGITransport(app=create_app()),
        base_url="http://testserver",
    ) as client:
        create_response = await client.post(
            "/tasks",
            json={"title": "Write baseline tests"},
        )
        list_response = await client.get("/tasks")

        assert create_response.status_code == 201
        created = create_response.json()
        assert created["title"] == "Write baseline tests"
        assert not created["completed"]
        assert isinstance(created["id"], str)
        assert created["id"]
        assert list_response.status_code == 200
        assert list_response.json() == [created]


@pytest.mark.anyio
async def test_create_task_rejects_empty_title() -> None:
    async with AsyncClient(
        transport=ASGITransport(app=create_app()),
        base_url="http://testserver",
    ) as client:
        response = await client.post("/tasks", json={"title": ""})

        assert response.status_code == 422
        list_response = await client.get("/tasks")
        assert list_response.json() == []
