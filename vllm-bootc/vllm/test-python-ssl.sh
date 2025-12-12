#!/usr/bin/env bash
# Test script to diagnose and fix Python SSL issues
set -euo pipefail

echo "[SSL-FIX] Testing Python SSL configuration..."

PYTHON_CMD="/opt/vllm-venv/bin/python"

# Test 1: Basic SSL context creation
echo "[SSL-FIX] Test 1: SSL context creation"
"${PYTHON_CMD}" -c "
import ssl
try:
    ctx = ssl.create_default_context()
    print('✓ SSL context creation: OK')
except Exception as e:
    print('✗ SSL context creation failed:', e)
    exit(1)
"

# Test 2: CA certificate bundle location
echo "[SSL-FIX] Test 2: CA certificate bundle"
"${PYTHON_CMD}" -c "
import ssl
import os
import certifi

print('System CA bundle paths:')
for path in [
    '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem',
    '/etc/ssl/certs/ca-certificates.crt',
    '/etc/ssl/certs/ca-bundle.crt'
]:
    if os.path.exists(path):
        print(f'✓ Found: {path}')
        break
else:
    print('✗ No system CA bundle found')

print(f'Certifi CA bundle: {certifi.where()}')
print(f'SSL default CA file: {ssl.get_default_verify_paths().cafile}')
"

# Test 3: HTTPS request
echo "[SSL-FIX] Test 3: HTTPS request to Hugging Face"
"${PYTHON_CMD}" -c "
import requests
import ssl
import os

# Force use of system CA bundle
os.environ['REQUESTS_CA_BUNDLE'] = '/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem'

try:
    print('Making HTTPS request to huggingface.co...')
    response = requests.get('https://huggingface.co', timeout=10)
    print(f'✓ HTTPS request successful: {response.status_code}')
except Exception as e:
    print(f'✗ HTTPS request failed: {e}')
    exit(1)
"

echo "[SSL-FIX] All SSL tests passed!"