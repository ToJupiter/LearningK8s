FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install -r /app/requirements.txt

COPY health.py /app/health.py

# The checker only binds a high port and talks to mongod - no privileges needed.
USER 65534:65534

EXPOSE 9201

CMD ["python", "-u", "/app/health.py"]
