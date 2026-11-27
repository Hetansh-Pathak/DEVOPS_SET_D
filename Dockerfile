FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8080

# Numeric UID/GID so Kubernetes runAsNonRoot can verify the user.
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /srv
COPY app/ ./app/

USER 10001:10001
EXPOSE 8080

# Uses only the Python standard library (no curl in slim image).
HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD ["python", "-c", "import os,sys,urllib.request; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:%s/healthz' % os.getenv('PORT','8080'), timeout=2).status == 200 else 1)"]

CMD ["python", "-m", "app.server"]
