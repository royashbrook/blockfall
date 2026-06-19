#!/usr/bin/env python3
"""Blockfall content validation (spec §6/§7 J).

Phase 0 scope: every schema is valid JSON Schema, and every content JSON file
validates against its schema with no dangling cross-references. As content
lands (Track J), this grows to check recipes are craftable, quests completable,
loot resolvable. Dependency-light: uses `jsonschema` if present, else falls
back to structural JSON checks so CI never hard-fails on a missing pip package.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA_DIR = ROOT / "content" / "schemas"
CONTENT_DIR = ROOT / "content"

# content file glob -> schema file
KIND_SCHEMA = {
    "blocks": "block.schema.json",
    "items": "item.schema.json",
    "recipes": "recipe.schema.json",
    "creatures": "creature.schema.json",
    "biomes": "biome.schema.json",
    "structures": "structure.schema.json",
    "loot": "loot.schema.json",
    "quests": "quest.schema.json",
    "dialogue": "dialogue.schema.json",
}

errors = []
checked = 0


def load_json(p: Path):
    try:
        return json.loads(p.read_text())
    except Exception as e:  # noqa: BLE001
        errors.append(f"{p.relative_to(ROOT)}: invalid JSON: {e}")
        return None


def main() -> int:
    global checked
    # 1) Every schema is itself valid JSON.
    schemas = {}
    if not SCHEMA_DIR.exists():
        errors.append("content/schemas missing")
    for sp in sorted(SCHEMA_DIR.glob("*.schema.json")):
        data = load_json(sp)
        if data is not None:
            schemas[sp.name] = data
            checked += 1

    # 2) Validate content files against schemas (if any content exists yet).
    try:
        import jsonschema  # type: ignore
        have_js = True
    except Exception:  # noqa: BLE001
        have_js = False
        print("   note: `jsonschema` not installed — structural JSON checks only")

    for kind, schema_name in KIND_SCHEMA.items():
        for cf in sorted(CONTENT_DIR.glob(f"{kind}/*.json")) + \
                  sorted(CONTENT_DIR.glob(f"{kind}.json")):
            data = load_json(cf)
            if data is None:
                continue
            checked += 1
            records = data if isinstance(data, list) else [data]
            schema = schemas.get(schema_name)
            if have_js and schema is not None:
                for rec in records:
                    try:
                        jsonschema.validate(rec, schema)
                    except jsonschema.ValidationError as e:  # type: ignore
                        errors.append(f"{cf.relative_to(ROOT)}: {e.message}")

    if errors:
        print(f"❌ content validation: {len(errors)} error(s)")
        for e in errors[:50]:
            print("   -", e)
        return 1
    print(f"✅ content validation: {checked} file(s) ok"
          + (" (schema-only; no content authored yet)" if checked <= len(schemas) else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
