#!/usr/bin/env python3
"""Download a pinned, digest-verified upstream binary. Never requires a GitHub token."""
import gzip, hashlib, json, pathlib, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = 'v1.19.32'
ASSET = f'mihomo-darwin-arm64-{VERSION}.gz'
SHA256 = '3312a6780652c622890fd4357c6a853bbf865464fd047ac7b7f52dab8de18652'
URL = f'https://github.com/MetaCubeX/mihomo/releases/download/{VERSION}/{ASSET}'
request = urllib.request.Request(URL, headers={'User-Agent': 'MihomoSwift-build'})
with urllib.request.urlopen(request, timeout=120) as response:
    data = response.read(100 * 1024 * 1024)
assert hashlib.sha256(data).hexdigest() == SHA256, 'Upstream digest mismatch'
binary = gzip.decompress(data)
assert binary[:8] == bytes.fromhex('cffaedfe0c000001'), 'Expected ARM64 Mach-O'
output = ROOT / 'Resources/mihomo'
output.write_bytes(binary)
output.chmod(0o755)
manifest = {'version': VERSION, 'asset': ASSET, 'url': URL, 'archiveSHA256': SHA256, 'binarySHA256': hashlib.sha256(binary).hexdigest()}
(ROOT / 'Resources/kernel-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Verified {VERSION} ARM64')
