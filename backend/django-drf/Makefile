# Reads config from environment variables injected by the root Makefile.
# See specs/orchestration.md for the contract.

.PHONY: dev test

dev:
	DATABASE_URL=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(POSTGRES_PORT)/$(POSTGRES_DB) \
	REDIS_URL=redis://localhost:$(REDIS_PORT) \
	SMTP_HOST=localhost \
	SMTP_PORT=${SMTP_PORT} \
	STORAGE_ENDPOINT=http://localhost:$(MINIO_PORT) \
	STORAGE_ACCESS_KEY=$(MINIO_ROOT_USER) \
	STORAGE_SECRET_KEY=$(MINIO_ROOT_PASSWORD) \
	poetry run python manage.py runserver 0.0.0.0:$(BACKEND_PORT)

test:
	DATABASE_URL=postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@localhost:$(POSTGRES_PORT)/$(POSTGRES_DB) \
	REDIS_URL=redis://localhost:$(REDIS_PORT) \
	SMTP_HOST=localhost \
	poetry run python manage.py test
