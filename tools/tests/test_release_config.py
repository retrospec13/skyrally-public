"""Offline configuration integration: generated modules are the real Rojo inputs."""
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess

import pytest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('configure_release', ROOT / 'tools/configure_release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def copy_inputs(tmp_path):
    for rel in ['src/server/AdminConfig.luau', 'src/shared/MonetizationConfig.luau']:
        dest = tmp_path / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / rel, dest)
    return tmp_path


def test_real_modules_configure_and_reset(tmp_path):
    root = copy_inputs(tmp_path)
    module.apply(dict(adminUserId=90000001, commerceEnabled=True, launchHide=False, receiptRecoveryEnabled=True), root)
    admin = root / 'src/server/AdminConfig.luau'
    commerce = root / 'src/shared/MonetizationConfig.luau'
    assert 'return create(90000001)' in admin.read_text()
    assert 'MonetizationConfig.Enabled = true' in commerce.read_text()
    assert 'MonetizationConfig.LAUNCH_HIDE = false' in commerce.read_text()
    assert 'MonetizationConfig.ReceiptRecoveryEnabled = true' in commerce.read_text()
    # Exercise generated source with Lune, not just string substitution.
    lune = shutil.which('lune')
    if lune:
        script = root / 'check.luau'
        script.write_text('local a = require("./src/server/AdminConfig")\n'
                          'local c = require("./src/shared/MonetizationConfig")\n'
                          'assert(a.isAdmin(90000001) and not a.isAdmin(90000002))\n'
                          'assert(c.Enabled and not c.LAUNCH_HIDE and c.ReceiptRecoveryEnabled)\n')
        subprocess.run([lune, 'run', str(script)], check=True, cwd=root)
    else:
        pytest.skip('Lune required for configuration runtime check')
    module.apply(json.loads((ROOT / 'config.example.json').read_text()), root)
    assert 'return create(0)' in admin.read_text()
    assert 'MonetizationConfig.Enabled = false' in commerce.read_text()


@pytest.mark.parametrize('config', [{'adminUserId': True}, {'adminUserId': -1}, {'adminUserId': '90000001'}, {'commerceEnabled': 'false'}, {'secret': 'not-supported'}])
def test_invalid_config_does_not_write(tmp_path, config):
    root = copy_inputs(tmp_path)
    before = {p: p.read_bytes() for p in root.rglob('*.luau')}
    with pytest.raises(ValueError):
        module.apply(config, root)
    assert all(p.read_bytes() == data for p, data in before.items())
