"""Keep the approved V2 sound sources, receipts and license scope together."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AUDIO = ROOT / 'assets/audio/sfx_v37'


def test_v2_audio_sources_match_receipt_and_files():
    sources = json.loads((AUDIO / 'SOURCES.json').read_text())
    receipt = json.loads((AUDIO / 'uploaded.json').read_text())
    rows = sources['files']
    assert len(rows) == 19
    assert {x['name'] for x in rows} == set(receipt)
    assert {x['name'] + '.ogg' for x in rows} == {x.name for x in AUDIO.glob('*.ogg')}
    for row in rows:
        f = ROOT / row['path']
        assert f == AUDIO / (row['name'] + '.ogg')
        assert f.stat().st_size == row['bytes']
        assert hashlib.sha256(f.read_bytes()).hexdigest() == row['sha256'] == receipt[row['name']]['sha256']
        assert row['roblox_id'] == receipt[row['name']]['id']
        assert row['duration_seconds'] > 0


def test_v2_audio_license_and_attribution_are_explicit():
    sources = json.loads((AUDIO / 'SOURCES.json').read_text())
    assert sources['license'] == 'CC-BY-4.0'
    assert sources['credit'] == 'Waku Worldwide'
    for row in sources['files']:
        assert row['license'] == sources['license']
        assert row['credit'] == sources['credit']
        assert 'ElevenLabs' in row['source']
    scope = (ROOT / 'LICENSING.md').read_text()
    assert 'Included V2 audio: CC BY 4.0' in scope
    assert 'assets/audio/sfx_v37/SOURCES.json' in scope


def test_v2_audio_inventory_is_included_not_excluded():
    rows = json.loads((AUDIO / 'SOURCES.json').read_text())['files']
    inventory = json.loads((ROOT / 'assets/V2-ASSETS.json').read_text())['audio_files']
    assert inventory == rows
    excluded = {x['path'] for x in json.loads((ROOT / 'EXCLUDED_FILES.json').read_text())}
    assert not ({x['path'] for x in rows} & excluded)
