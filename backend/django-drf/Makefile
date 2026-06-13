# Reads config from environment variables injected by the root Makefile.
# See specs/orchestration.md for the contract (dev / lint / test).
#
# Run via the root orchestrator so the shared infra + .env are wired up:
#   make dev   BACK=django-drf   (or: make pair FRONT=<x> BACK=django-drf)
#   make lint  BACK=django-drf
#   make test  BACK=django-drf

.PHONY: dev lint test

dev:
	REDIS_URL=redis://localhost:$(REDIS_PORT) \
	SMTP_HOST=localhost \
	STORAGE_ENDPOINT=http://localhost:$(MINIO_PORT) \
	STORAGE_ACCESS_KEY=$(MINIO_ROOT_USER) \
	STORAGE_SECRET_KEY=$(MINIO_ROOT_PASSWORD) \
	poetry run python manage.py runserver 0.0.0.0:$(BACKEND_PORT)

lint:
	poetry install --no-interaction --with dev
	poetry run ruff check .
	poetry run ruff format --check .
	SMTP_HOST=localhost \
	poetry run mypy .

test:
	poetry install --no-interaction
	REDIS_URL=redis://localhost:$(REDIS_PORT) \
	SMTP_HOST=localhost \
	poetry run python manage.py test
