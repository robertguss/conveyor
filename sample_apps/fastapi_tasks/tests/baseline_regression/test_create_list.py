from unittest import TestCase

import pytest
from httpx import ASGITransport, AsyncClient

from fastapi_tasks.app import create_app


CASE = TestCase()


@pytest.fixture
def anyio_backend() -> str:
    return "asyncio"


@pytest.fixture
async def client() -> AsyncClient:
    async with AsyncClient(
        transport=ASGITransport(app=create_app()),
        base_url="http://testserver",
    ) as test_client:
        yield test_client


@pytest.mark.anyio
async def test_baseline_regression_starts_with_empty_task_list(client: AsyncClient) -> None:
    response = await client.get("/tasks")

    CASE.assertEqual(response.status_code, 200)
    CASE.assertEqual(response.json(), [])


@pytest.mark.anyio
async def test_baseline_regression_create_defaults_to_incomplete(client: AsyncClient) -> None:
    response = await client.post("/tasks", json={"title": "Capture baseline"})

    CASE.assertEqual(response.status_code, 201)
    created = response.json()
    CASE.assertEqual(created["title"], "Capture baseline")
    CASE.assertFalse(created["completed"])
    CASE.assertIsInstance(created["id"], str)
    CASE.assertTrue(created["id"])


@pytest.mark.anyio
async def test_baseline_regression_created_tasks_are_listed_in_order(client: AsyncClient) -> None:
    first = (await client.post("/tasks", json={"title": "First baseline task"})).json()
    second = (await client.post("/tasks", json={"title": "Second baseline task"})).json()

    response = await client.get("/tasks")

    CASE.assertEqual(response.status_code, 200)
    CASE.assertEqual(response.json(), [first, second])


@pytest.mark.anyio
async def test_baseline_regression_rejected_create_does_not_change_list(client: AsyncClient) -> None:
    create_response = await client.post("/tasks", json={"title": ""})
    list_response = await client.get("/tasks")

    CASE.assertEqual(create_response.status_code, 422)
    CASE.assertEqual(list_response.status_code, 200)
    CASE.assertEqual(list_response.json(), [])
