"""Real socket tests for the production client adapter and app TLS wrapper."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('--harness', type=Path, required=True)
parser.add_argument('--fixtures', type=Path, required=True)
args = parser.parse_args()
root = args.fixtures
server_fp = hashlib.sha256(ssl.PEM_cert_to_DER_cert((root / 'server.crt').read_text())).hexdigest().upper()
client_fp = hashlib.sha256(ssl.PEM_cert_to_DER_cert((root / 'client.crt').read_text())).hexdigest().upper()
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_2
context.load_cert_chain(root / 'server.crt', root / 'server.key')
context.verify_mode = ssl.CERT_REQUIRED
context.load_verify_locations(root / 'client.crt')
checks = 0

def case(name, response=b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello', *,
         expected=server_fp, mode='transfer', success=True, body='hello',
         app_bytes=True, shutdown='hold', fragmented=False, file=None):
    global checks
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0)); listener.listen(1); listener.settimeout(8)
    port = listener.getsockname()[1]
    release_server = threading.Event()
    observed = {'bytes': b'', 'error': None}
    def serve():
        try:
            raw, _ = listener.accept(); raw.settimeout(8)
            with context.wrap_socket(raw, server_side=True) as tls:
                observed['client_fp'] = hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest().upper()
                while b'\r\n\r\n' not in observed['bytes']:
                    part = tls.recv(65536)
                    if not part: return
                    observed['bytes'] += part
                header, payload = observed['bytes'].split(b'\r\n\r\n', 1)
                content_length = int(next(line.split(b':', 1)[1] for line in header.split(b'\r\n') if line.lower().startswith(b'content-length:')))
                while len(payload) < content_length:
                    part = tls.recv(65536)
                    if not part: break
                    payload += part
                observed['payload'] = payload
                observed['header'] = header
                if fragmented:
                    for byte in response:
                        tls.sendall(bytes([byte]))
                else:
                    tls.sendall(response)
                if shutdown == 'abrupt':
                    os.close(tls.detach())
                elif shutdown == 'clean':
                    try: tls.unwrap().close()
                    except OSError: pass
                else:
                    release_server.wait(10)
        except (ssl.SSLError, OSError) as exc:
            observed['error'] = str(exc)
        finally:
            listener.close()
    thread = threading.Thread(target=serve, daemon=True); thread.start()
    command = [str(args.harness), str(root/'client.p12'), str(port), expected, mode]
    if file: command.append(str(file))
    start = time.monotonic()
    try:
        result = subprocess.run(command, text=True, capture_output=True, timeout=9)
    finally:
        release_server.set()
    thread.join(3)
    assert not thread.is_alive(), (name, 'server did not finish')
    assert result.returncode == 0, (name, result.stdout, result.stderr)
    assert 'Sanitizer' not in result.stderr, (name, result.stderr)
    report = json.loads(result.stdout)
    assert report['completed'] == success, (name, report, observed['error'])
    assert observed.get('client_fp') == client_fp, (name, 'wrong/no client certificate', observed)
    if success:
        assert report['status'] == 200 and report['body'] == body, (name, report)
        assert report['pin'] == server_fp, (name, 'wrong learned/pinned certificate')
    else:
        assert report.get('error'), (name, report)
    assert bool(observed['bytes']) == app_bytes, (name, 'application bytes leaked or missing', observed)
    if not app_bytes:
        assert report['pin'] == '', (name, 'wrong certificate stored')
    if app_bytes:
        assert observed['payload'] == (file.read_bytes() if file else (b'private-discovery-data' if mode == 'discovery' else b'private-transfer-data')), (name, 'payload changed')
        if mode == 'discovery': assert observed['header'].startswith(b'POST /api/localsend/v2/register HTTP/1.1')
    if shutdown == 'hold': assert time.monotonic() - start < 5, (name, 'waited for EOF')
    checks += 1
    print('PASS', name, flush=True)

case('pinned mutual TLS sends body and completes without EOF')
case('wrong transfer pin sends zero HTTP bytes', expected='0'*64, success=False, app_bytes=False)
case('missing transfer pin sends zero HTTP bytes', expected='-', success=False, app_bytes=False)
case('malformed transfer pin sends zero HTTP bytes', expected='invalid', success=False, app_bytes=False)
case('unknown discovery learns peer certificate', expected='-', mode='discovery')
case('wrong advertised discovery pin sends zero HTTP bytes', expected='0'*64, mode='discovery', success=False, app_bytes=False)
case('fixed body survives one-byte TLS records', fragmented=True)
case('chunked body and trailers complete before EOF', response=b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3\r\nllo\r\n0\r\nX-Info: value\r\n\r\n', fragmented=True)
case('complete framed response permits subsequent bare TCP close', shutdown='abrupt')
case('truncated fixed response rejected on bare TCP close', response=b'HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhello', shutdown='abrupt', success=False)
case('truncated fixed response rejected on close_notify', response=b'HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhello', shutdown='clean', success=False)
case('close-delimited response requires authenticated EOF', response=b'HTTP/1.1 200 OK\r\n\r\nhello', shutdown='abrupt', success=False)
case('close-delimited response accepted with close_notify', response=b'HTTP/1.1 200 OK\r\n\r\nhello', shutdown='clean')
case('missing chunk trailer terminator rejected', response=b'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n', shutdown='clean', success=False)
case('ambiguous lengths rejected', response=b'HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello', shutdown='clean', success=False)
case('oversized API body rejected from declared length', response=b'HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n', success=False)
file = root / 'large-photo.bin'; file.write_bytes(bytes(range(256)) * 8192)
case('2 MiB photo file streams intact over app TLS', file=file)
def raw_peer_case(name, plaintext):
    global checks
    listener = socket.socket()
    listener.bind(('127.0.0.1', 0)); listener.listen(1); listener.settimeout(8)
    release_server = threading.Event()
    observed = []
    def serve():
        try:
            raw, _ = listener.accept()
            with raw:
                raw.settimeout(8)
                observed.append(raw.recv(65536))
                if plaintext:
                    raw.sendall(b'HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n')
                    while True:
                        try: part = raw.recv(65536)
                        except ConnectionResetError: break
                        if not part: break
                        observed.append(part)
                else:
                    release_server.wait(8)
        finally:
            listener.close()
    port = listener.getsockname()[1]
    thread = threading.Thread(target=serve, daemon=True); thread.start()
    start = time.monotonic()
    try:
        result = subprocess.run([str(args.harness), str(root/'client.p12'), str(port), '-', 'discovery'], text=True, capture_output=True, timeout=7)
    finally:
        release_server.set()
    thread.join(2)
    assert not thread.is_alive(), name
    assert result.returncode == 0, (name, result.stderr)
    assert 'Sanitizer' not in result.stderr, (name, result.stderr)
    report = json.loads(result.stdout)
    assert not report['completed'] and report['error'], (name, report)
    assert observed and observed[0][0] == 22, (name, 'did not send TLS ClientHello')
    assert b'POST ' not in b''.join(observed) and b'private-discovery-data' not in b''.join(observed), (name, 'plaintext application data leaked')
    elapsed = time.monotonic() - start
    assert elapsed < 5.5, (name, elapsed)
    if not plaintext: assert elapsed >= 3.5, (name, 'discovery deadline too early', elapsed)
    checks += 1
    print('PASS', name, flush=True)

raw_peer_case('plaintext-only peer fails without HTTP fallback', True)
raw_peer_case('stalled discovery TLS handshake obeys four-second deadline', False)
print(f'{checks}/{checks} real TLS client tests passed')
