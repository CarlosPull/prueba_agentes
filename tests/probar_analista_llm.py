#!/usr/bin/env python3
"""Validación aislada de destinos del LLM, sin Ollama ni red."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("analista", Path(__file__).resolve().parents[1] / "tools/orquestacion/analizar_con_llm.py")
analista = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analista)


class PruebasDestinos(unittest.TestCase):
    def setUp(self):
        self.inventory = [dict(profile="vm", repository=name, module=name, stack="backend", workspace=f"/{name}") for name in ["pagos", "comments"]]
        self.req = dict(target_profile="vm", repository="pagos", module="pagos", category="backend", text="Consultar pagos")

    def test_dos_repositorios_en_una_vm(self):
        result = analista.enriquecer_requisitos([self.req], self.inventory)
        self.assertEqual(result[0]["workspace"], "/pagos")

    def test_destino_desconocido_no_se_reasigna(self):
        for field, value in [("target_profile", "otra-vm"), ("repository", "ajeno"), ("module", "otro"), ("category", "frontend"), ("text", "")]:
            with self.subTest(field=field), self.assertRaises(analista.DestinoInvalido):
                analista.enriquecer_requisitos([self.req | {field: value}], self.inventory)

    def test_no_acepta_respuestas_parciales(self):
        with self.assertRaises(analista.DestinoInvalido):
            analista.enriquecer_requisitos([self.req, self.req | {"repository": "ajeno"}], self.inventory)

    def test_inventario_duplicado(self):
        with self.assertRaises(analista.DestinoInvalido):
            analista.enriquecer_requisitos([self.req], self.inventory + [self.inventory[0]])

    def test_identificadores_no_escalares(self):
        for field in ["target_profile", "repository", "module", "category"]:
            with self.subTest(field=field), self.assertRaises(analista.DestinoInvalido):
                analista.enriquecer_requisitos([self.req | {field: []}], self.inventory)


if __name__ == "__main__":
    unittest.main()
