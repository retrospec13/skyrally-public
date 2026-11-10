#!/usr/bin/env python3
"""Apply a local JSON configuration to the actual modules packaged by Rojo.

Usage: python3 tools/configure_release.py config.example.json
No API calls, uploads, grants or publication. Keep real local config out of Git.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def apply(config, root=ROOT):
    allowed = {'adminUserId', 'commerceEnabled', 'launchHide', 'receiptRecoveryEnabled'}
    if set(config) - allowed:
        raise ValueError('Unknown configuration fields')
    admin = config.get('adminUserId', 0)
    if type(admin) is not int or not 0 <= admin <= 9007199254740991:
        raise ValueError('adminUserId must be zero (disabled) or a positive safe integer')
    flags = {k: config.get(k, default) for k, default in
             [('commerceEnabled', False), ('launchHide', True), ('receiptRecoveryEnabled', False)]}
    if any(type(v) is not bool for v in flags.values()):
        raise ValueError('Commerce settings must be JSON booleans')
    admin_path = root / 'src/server/AdminConfig.luau'
    commerce_path = root / 'src/shared/MonetizationConfig.luau'
    admin_text, count = re.subn(r'return create\(\d+\)\s*$', f'return create({admin})\n', admin_path.read_text())
    if count != 1:
        raise ValueError('Admin module format changed; no files written')
    commerce_text = commerce_path.read_text()
    for field, key in [('Enabled', 'commerceEnabled'), ('LAUNCH_HIDE', 'launchHide'),
                       ('ReceiptRecoveryEnabled', 'receiptRecoveryEnabled')]:
        commerce_text, count = re.subn(rf'MonetizationConfig\.{field} = (true|false)',
                                     f'MonetizationConfig.{field} = {str(flags[key]).lower()}', commerce_text)
        if count != 1:
            raise ValueError('Commerce module format changed; no files written')
    admin_path.write_text(admin_text)
    commerce_path.write_text(commerce_text)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config', type=Path)
    args = parser.parse_args()
    apply(json.loads(args.config.read_text()))
    print('Configured local runtime modules. No remote changes made.')
