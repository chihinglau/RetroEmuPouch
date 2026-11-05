"""首次部署 seed —— 在 app 容器内执行：

    docker compose -f docker-compose.prod.yml exec -T app python -m app.cli_seed

直接调用 seed 服务，不经过 HTTP / admin token；避免 `python -c "..."`
经过 PowerShell → ssh → bash 多层引号被吞导致的 syntax error。
"""
from __future__ import annotations

from .database import SessionLocal
from .services import seed


def main() -> None:
    db = SessionLocal()
    try:
        result = seed.run_seed(db)
        print(f"[seed] {result}")
    finally:
        db.close()


if __name__ == "__main__":
    main()
