import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

import psycopg


HOST = "0.0.0.0"
PORT = int(os.getenv("PORT", "8080"))


def database_status() -> dict[str, str]:
    with psycopg.connect(
        host=os.environ["DB_HOST"],
        port=int(os.getenv("DB_PORT", "5432")),
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        connect_timeout=3,
    ) as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            result = cursor.fetchone()
    if result != (1,):
        raise RuntimeError("unexpected database result")
    return {"status": "ok", "database": "postgresql"}


class RequestHandler(BaseHTTPRequestHandler):
    def _send_json(self, status: int, payload: dict[str, str]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - required by BaseHTTPRequestHandler
        path = urlsplit(self.path).path
        if path == "/health":
            self._send_json(200, {"status": "ok", "service": "python-api"})
            return
        if path == "/db":
            try:
                self._send_json(200, database_status())
            except Exception as error:  # The lab endpoint should expose a useful failure.
                self._send_json(503, {"status": "error", "detail": str(error)})
            return
        if path == "/":
            self._send_json(200, {"service": "python-api", "endpoints": "/health, /db"})
            return
        self._send_json(404, {"status": "not_found"})

    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.address_string()} - {format % args}")


if __name__ == "__main__":
    server = ThreadingHTTPServer((HOST, PORT), RequestHandler)
    print(f"listening on {HOST}:{PORT}", flush=True)
    server.serve_forever()
