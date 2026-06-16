from collections import OrderedDict
from threading import Lock
from uuid import uuid4

from fastapi import FastAPI, status
from pydantic import BaseModel, ConfigDict, Field


class TaskCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=200)
    completed: bool = False


class Task(TaskCreate):
    id: str


class TaskStore:
    def __init__(self) -> None:
        self._lock = Lock()
        self._tasks: OrderedDict[str, Task] = OrderedDict()

    def list_tasks(self) -> list[Task]:
        with self._lock:
            return list(self._tasks.values())

    def create_task(self, payload: TaskCreate) -> Task:
        task = Task(id=str(uuid4()), title=payload.title, completed=payload.completed)
        with self._lock:
            self._tasks[task.id] = task
        return task


def create_app(store: TaskStore | None = None) -> FastAPI:
    task_store = store or TaskStore()
    app = FastAPI(
        title="Conveyor FastAPI Tasks Sample",
        version="0.1.0",
        docs_url="/docs",
        redoc_url=None,
    )

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/tasks", response_model=list[Task])
    def list_tasks() -> list[Task]:
        return task_store.list_tasks()

    @app.post("/tasks", response_model=Task, status_code=status.HTTP_201_CREATED)
    def create_task(payload: TaskCreate) -> Task:
        return task_store.create_task(payload)

    return app


app = create_app()
