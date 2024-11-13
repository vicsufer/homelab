#!/usr/bin/env python3

import os

try:
    cwd = os.getcwd() with open(cwd + '/.pass.txt') as f:
        password = f.read()
        password.replace('\n', '')
except OSError:
    password = 'Empty'

print(os.getenv('VAULT_PASSWORD', password))
