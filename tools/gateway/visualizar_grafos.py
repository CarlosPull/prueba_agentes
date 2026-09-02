#!/usr/bin/env python3
"""Servidor local para explorar los grafos de Cognee a través del Memory Gateway."""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlparse
from urllib.request import Request, urlopen


HTML_PATH = Path(__file__).with_name("visualizador_grafos.html")


class GatewayError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status


class GatewayClient:
    def __init__(self, base_url: str, cert: str, key: str, ca: str, timeout: int = 70):
        if not base_url.startswith("https://"):
            raise ValueError("MEMORY_GATEWAY_URL debe usar https://")
        if not ssl.HAS_TLSv1_3:
            raise ValueError("este Python no soporta TLS 1.3; usa .private/cognee-venv/bin/python")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.context = ssl.create_default_context(cafile=ca)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_3
        self.context.load_cert_chain(certfile=cert, keyfile=key)

    def post(self, path: str, payload: dict) -> dict:
        request = Request(
            f"{self.base_url}{path}",
            data=json.dumps(payload).encode("utf-8"),
            headers={"content-type": "application/json", "accept": "application/json"},
            method="POST",
        )
        try:
            with urlopen(request, context=self.context, timeout=self.timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as error:
            try:
                detail = json.loads(error.read().decode("utf-8")).get("error", "error del Gateway")
            except (json.JSONDecodeError, UnicodeDecodeError):
                detail = "error del Gateway"
            raise GatewayError(error.code, detail) from error
        except (URLError, TimeoutError, ssl.SSLError) as error:
            raise GatewayError(502, f"no se pudo conectar con el Memory Gateway: {error.reason if hasattr(error, 'reason') else error}") from error
        except json.JSONDecodeError as error:
            raise GatewayError(502, "el Memory Gateway devolvió JSON inválido") from error

    def datasets(self) -> dict:
        return self.post("/v1/admin/graphs/datasets", {})

    def graph(self, payload: dict) -> dict:
        return self.post("/v1/admin/graphs/view", payload)


def handler_for(client: GatewayClient, html: bytes):
    class ViewerHandler(BaseHTTPRequestHandler):
        server_version = "VisorMemoria/1.0"

        def send_bytes(self, status: int, body: bytes, content_type: str) -> None:
            self.send_response(status)
            self.send_header("content-type", content_type)
            self.send_header("content-length", str(len(body)))
            self.send_header("cache-control", "no-store")
            self.send_header("x-content-type-options", "nosniff")
            self.send_header("content-security-policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:")
            self.end_headers()
            self.wfile.write(body)

        def send_json(self, status: int, payload: dict) -> None:
            self.send_bytes(status, json.dumps(payload, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

        def do_GET(self) -> None:  # noqa: N802
            parsed = urlparse(self.path)
            try:
                if parsed.path == "/":
                    self.send_bytes(200, html, "text/html; charset=utf-8")
                    return
                if parsed.path == "/api/datasets":
                    self.send_json(200, client.datasets())
                    return
                if parsed.path == "/api/graph":
                    query = parse_qs(parsed.query)
                    dataset_id = query.get("dataset_id", [""])[0]
                    if not dataset_id:
                        raise GatewayError(400, "dataset_id es obligatorio")
                    payload = {
                        "dataset_id": dataset_id,
                        "query": query.get("query", [""])[0][:1000],
                        "max_nodes": int(query.get("max_nodes", ["250"])[0]),
                        "neighborhood_depth": int(query.get("neighborhood_depth", ["2"])[0]),
                        "full": query.get("full", ["false"])[0].lower() == "true",
                    }
                    self.send_json(200, client.graph(payload))
                    return
                self.send_json(404, {"error": "ruta no encontrada"})
            except (ValueError, OverflowError):
                self.send_json(400, {"error": "parámetros numéricos no válidos"})
            except GatewayError as error:
                self.send_json(error.status, {"error": str(error)})
            except Exception:
                self.send_json(500, {"error": "error interno del visualizador"})

        def log_message(self, pattern: str, *args: object) -> None:
            sys.stderr.write(f"[visualizador] {self.address_string()} {pattern % args}\n")

    return ViewerHandler


def required_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"falta la variable {name}")
    return value


def required_file(name: str) -> str:
    value = Path(required_env(name)).expanduser()
    if not value.is_file():
        raise ValueError(f"{name} apunta a un archivo inexistente: {value}")
    return str(value)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Visualiza en vivo los grafos administrados por el Memory Gateway.")
    parser.add_argument("--host", default="127.0.0.1", help="interfaz local (predeterminado: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=8765, help="puerto local (predeterminado: 8765)")
    parser.add_argument("--abrir", action="store_true", help="abrir el navegador al iniciar")
    parser.add_argument("--permitir-red", action="store_true", help="permitir publicar el visor fuera de localhost")
    return parser.parse_args()


def main() -> int:
    args = arguments()
    if not 1 <= args.port <= 65535:
        raise ValueError("--port debe estar entre 1 y 65535")
    if args.host not in {"127.0.0.1", "localhost", "::1"} and not args.permitir_red:
        raise ValueError("usa --permitir-red para exponer el visualizador fuera de localhost")
    client = GatewayClient(
        required_env("MEMORY_GATEWAY_URL"),
        required_file("MEMORY_GATEWAY_CLIENT_CERT"),
        required_file("MEMORY_GATEWAY_CLIENT_KEY"),
        required_file("MEMORY_GATEWAY_CA"),
    )
    html = HTML_PATH.read_bytes()
    server = ThreadingHTTPServer((args.host, args.port), handler_for(client, html))
    url = f"http://{args.host}:{server.server_port}/"
    print(f"Visualizador disponible en {url}")
    print("Las credenciales mTLS permanecen en este proceso y no se envían al navegador.")
    if args.abrir:
        webbrowser.open(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nVisualizador detenido.")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr)
        raise SystemExit(1) from error
