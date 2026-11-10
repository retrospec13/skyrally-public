"""Offline source-distribution contract, independent of hosted Roblox access."""
import hashlib
import json
import struct
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_five_bosses_have_local_rigs_and_authoritative_clips():
    roster = json.loads((ROOT / 'models/BOSS-SOURCES.json').read_text())['roster']
    assert {r['name'] for r in roster} == {'Cinderwing', 'Frosthorn', 'Clattershell', 'Emberbeetle', 'Thunderwright'}
    for row in roster:
        for key in ('rig_geometry_textures', 'animation_glb', 'authoritative_clip', 'runtime_player', 'clip_math', 'standalone_preview_player'):
            assert (ROOT / row[key]).is_file(), row[key]
        text = (ROOT / row['authoritative_clip']).read_text()
        body = text[text.index('local clips:'):].strip()
        assert hashlib.sha256(body.encode()).hexdigest() == row['clip_body_sha256']
        data = (ROOT / row['rig_geometry_textures']).read_bytes()
        assert data[:4] == b'glTF'
        length = struct.unpack_from('<I', data, 12)[0]
        doc = json.loads(data[20:20 + length])
        assert doc['meshes'] and doc['skins'] and doc['images']
        assert all('bufferView' in image for image in doc['images'])
        assert all('uri' not in buffer for buffer in doc['buffers'])
        assert row['animation_glb_matches_shipped'] == (row['name'] != 'Frosthorn')


def test_pack_has_seven_real_modules_and_verbatim_sources():
    root = ET.parse(ROOT / 'models/WakuPublicBossPack.rbxmx').getroot()
    modules = [x for x in root.iter('Item') if x.attrib['class'] in ('Script', 'LocalScript', 'ModuleScript')]
    assert len(modules) == 7
    manifest = json.loads((ROOT / 'models/BOSS-PACK-SCRIPTS.json').read_text())
    sources = []
    for item in modules:
        assert item.attrib['class'] == 'ModuleScript'
        props = item.find('Properties')
        source = [x for x in props if x.attrib.get('name') == 'Source' and x.tag in ('string', 'ProtectedString')]
        assert len(source) == 1 and source[0].text
        sources.append(source[0].text.encode())
    for row in manifest:
        data = (ROOT / row['source_file']).read_bytes()
        assert len(data) == row['source_bytes']
        assert hashlib.sha256(data).hexdigest() == row['sha256']
        assert data in sources


def test_source_payload_not_lfs_or_nested_out_ignored():
    attributes = (ROOT / '.gitattributes').read_text()
    assert 'filter=lfs' not in attributes
    assert 'out/' not in (ROOT / '.gitignore').read_text().splitlines()
    assert '/out/' in (ROOT / '.gitignore').read_text().splitlines()
