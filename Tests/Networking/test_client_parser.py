"""Exercise the actual client framing/pinning helpers on macOS Foundation."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parent
app_dir = Path(os.environ.get('LOCALSEND_SOURCE_DIR', root.parent.parent / 'Sources'))
with tempfile.TemporaryDirectory(prefix='localsend-parser-tests-') as directory:
    path = root / 'response_parser_tests.m'
    binary = Path(directory) / 'client_parser_harness'
    subprocess.run([
        'xcrun', 'clang', '-framework', 'Foundation', '-Wall', '-Wextra', '-Werror',
        '-fsanitize=address,undefined', '-I', str(app_dir / 'Networking'), '-I', str(app_dir / 'Security'), '-o', str(binary), str(path),
        str(app_dir / 'Networking/LocalSendHTTPResponseParser.m'),
        str(app_dir / 'Security/LocalSendCertificateFingerprint.m'),
    ], check=True)
    result = subprocess.run([str(binary)], capture_output=True, text=True)
print(result.stdout, end='')
print(result.stderr, end='')
raise SystemExit(result.returncode)
