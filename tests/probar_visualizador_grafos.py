#!/usr/bin/env python3
"""Prueba HTTP aislada del visualizador, sin credenciales ni servicios reales."""

import importlib.util
import json
import threading
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import urlopen


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "gateway" / "visualizar_grafos.py"
spec = importlib.util.spec_from_file_location("visualizar_grafos", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FakeGateway:
    def __init__(self):
        self.last_payload = None

    def datasets(self):
        return {"datasets": [{"id": "11111111-1111-4111-8111-111111111111", "name": "prueba_agentes_demo"}]}

    def graph(self, payload):
        self.last_payload = payload
        return {"dataset": {"id": payload["dataset_id"]}, "graph": {"nodes": [{"id": "a"}], "links": []}}


fake = FakeGateway()
html = (ROOT / "tools" / "gateway" / "visualizador_grafos.html").read_bytes()
server = module.ThreadingHTTPServer(("127.0.0.1", 0), module.handler_for(fake, html))
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
base = f"http://127.0.0.1:{server.server_port}"

try:
    page = urlopen(f"{base}/", timeout=2).read().decode("utf-8")
    assert "Mapa vivo de memoria" in page
    datasets = json.load(urlopen(f"{base}/api/datasets", timeout=2))
    assert datasets["datasets"][0]["name"] == "prueba_agentes_demo"
    graph = json.load(urlopen(f"{base}/api/graph?dataset_id=11111111-1111-4111-8111-111111111111&max_nodes=100&query=Laravel", timeout=2))
    assert graph["graph"]["nodes"][0]["id"] == "a"
    assert fake.last_payload["max_nodes"] == 100 and fake.last_payload["query"] == "Laravel"
    try:
        urlopen(f"{base}/api/graph", timeout=2)
        raise AssertionError("dataset_id vacío no fue rechazado")
    except HTTPError as error:
        assert error.code == 400
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)

print("OK: HTML y proxy Python del visualizador verificados.")
