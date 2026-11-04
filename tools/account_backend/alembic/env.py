"""Alembic 环境 —— 复用 app.database 的 Base / engine，DATABASE_URL 取自配置。"""
from logging.config import fileConfig

from alembic import context

import os
import sys

# 让 `import app` 可用（alembic.ini 的 prepend_sys_path = . 已把项目根加入，
# 这里再保险一次）。
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.database import Base, engine  # noqa: E402
from app import models  # noqa: F401  # 触发所有 model 注册到 Base.metadata
from app.config import settings  # noqa: E402

config = context.config

if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# 用运行时配置覆盖 sqlalchemy.url（优先环境变量 / .env 的 DATABASE_URL）。
config.set_main_option("sqlalchemy.url", settings.DATABASE_URL)

target_metadata = Base.metadata


def run_migrations_offline() -> None:
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        compare_type=True,
    )
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    with engine.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
            compare_type=True,
        )
        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
