"""Offline source-kit packaging checks; never contacts Roblox."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_present_source_and_rights_manifests():
    for name in ('models/LOCAL-MODEL-SOURCES.json', 'assets/RIGHTS-INVENTORY.json'):
        rows = json.loads((ROOT / name).read_text())['files']
        assert rows
        assert len({row['path'] for row in rows}) == len(rows)
        for row in rows:
            path = ROOT / row['path']
            assert path.is_file(), row['path']
            assert hashlib.sha256(path.read_bytes()).hexdigest() == row['sha256'], row['path']


def test_exclusions_are_absent_and_unique():
    rows = json.loads((ROOT / 'EXCLUDED_FILES.json').read_text())
    assert len({row['path'] for row in rows}) == len(rows)
    assert all(not (ROOT / row['path']).exists() for row in rows)


def test_rojo_paths_and_map_count():
    project = json.loads((ROOT / 'default.project.json').read_text())
    def walk(node):
        if isinstance(node, dict):
            if '$path' in node:
                assert (ROOT / node['$path']).exists(), node['$path']
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(project)
    maps = project['tree']['ServerScriptService']['Maps']
    assert len([k for k in maps if not k.startswith('$')]) == 7


def test_moved_helpers_and_boss_sources():
    for path in ('tools/windows/key_pilot.js', 'tools/legacy-builders/builder_forest1.luau',
                 'tools/legacy-builders/builder_snow1.luau', 'builder_dino4.luau'):
        assert (ROOT / path).is_file()
    for boss in ('Cinderwing', 'Frosthorn', 'Clattershell', 'Emberbeetle', 'Thunderwright'):
        assert (ROOT / 'src/shared/bossclips' / (boss + '.luau')).is_file()
    for folder in ('dino_boss', 'snow_boss', 'island_boss', 'forest_boss', 'hub_boss'):
        assert (ROOT / 'assets/models/bosses' / folder / 'anim/out/rigged.glb').is_file()
    assert (ROOT / 'assets/models/bosses/snow_boss/anim/out/historical-anim.glb').is_file()
