import argparse, subprocess, socket, ssl, pathlib, json, hashlib, time
parser = argparse.ArgumentParser()
parser.add_argument('--harness', type=pathlib.Path, required=True)
parser.add_argument('--fixtures', type=pathlib.Path, required=True)
args = parser.parse_args()
root = args.fixtures
p=subprocess.Popen([str(args.harness),str(root/'server.p12')],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
    line=p.stdout.readline().strip()
    if not line: raise RuntimeError(p.stderr.read())
    port=int(line)
    ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
    ctx.minimum_version=ctx.maximum_version=ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(root/'client.crt',root/'client.key')
    def connect(tls=True):
        sock=socket.create_connection(('127.0.0.1',port),timeout=5)
        return ctx.wrap_socket(sock,server_hostname='localhost') if tls else sock
    def exchange(request,tls=True):
        with connect(tls) as s:
            s.sendall(request)
            response=b''
            while True:
                part=s.recv(65536)
                if not part: break
                response+=part
            return response
    def check(name,request,expected,tls=True,body=None):
        response=exchange(request,tls)
        assert response.startswith(('HTTP/1.1 %d '%expected).encode()), (name,response[:300])
        if body is not None: assert response.split(b'\r\n\r\n',1)[1]==body, (name,response[:300])
        print('PASS',name,flush=True)
    def req(path='/api/localsend/v2/info',method='GET',headers='',body=b''):
        return (method+' '+path+' HTTP/1.1\r\nHost: test\r\n'+headers+'\r\n').encode()+body
    check('plaintext info',req(),200,False)
    check('TLS info with self-signed client',req(),200)
    info=json.loads(exchange(req()).split(b'\r\n\r\n')[1])
    der=ssl.PEM_cert_to_DER_cert((root/'client.crt').read_text())
    assert info['peer']['fingerprint']==hashlib.sha256(der).hexdigest().upper()
    print('PASS peer fingerprint equals actual TLS client certificate',flush=True)
    check('plaintext transfer rejected',req('/api/localsend/v2/prepare-upload','POST'),426,False)
    check('plaintext upload rejected',req('/api/localsend/v2/upload?token=ok&size=5','POST','Content-Length: 5\r\n',b'hello'),426,False)
    check('fixed metadata body preserved',req('/api/localsend/v2/register','POST','Content-Length: 5\r\n',b'hello'),200,False,b'hello')
    check('chunked metadata decoded',req('/api/localsend/v2/register','POST','Transfer-Encoding: chunked\r\n',b'2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n'),200,False,b'hello')
    check('chunk extension and trailer',req('/api/localsend/v2/register','POST','Transfer-Encoding: chunked\r\n',b'5;test=value\r\nhello\r\n0\r\nDigest: x\r\n\r\n'),200,False,b'hello')
    upload='/api/localsend/v2/upload?token=ok&size=5'
    check('fixed upload commits',req(upload,'POST','Content-Length: 5\r\n',b'hello'),200)
    check('chunked upload commits',req(upload,'POST','Transfer-Encoding: chunked\r\n',b'5\r\nhello\r\n0\r\n\r\n'),200)
    check('zero byte upload commits',req('/api/localsend/v2/upload?token=ok&size=0','POST','Content-Length: 0\r\n'),200)
    check('upload token rejected before continue',req('/api/localsend/v2/upload?token=bad','POST','Content-Length: 5\r\nExpect: 100-continue\r\n'),403)
    with connect() as s:
        s.sendall(req(upload,'POST','Content-Length: 5\r\nExpect: 100-continue\r\n'))
        response=s.recv(4096); assert response==b'HTTP/1.1 100 Continue\r\n\r\n',response
        s.sendall(b'hello'); response=s.recv(4096); assert response.startswith(b'HTTP/1.1 200 '),response
    print('PASS authorized upload receives 100 Continue',flush=True)
    for name,h in [('negative length','Content-Length: -1\r\n'),('signed length','Content-Length: +5\r\n'),('nondecimal length','Content-Length: 5a\r\n'),('overflow length','Content-Length: 9223372036854775808\r\n'),('duplicate lengths','Content-Length: 5\r\nContent-Length: 5\r\n'),('CL plus TE','Content-Length: 5\r\nTransfer-Encoding: chunked\r\n'),('unknown transfer encoding','Transfer-Encoding: gzip, chunked\r\n'),('folded header',' X: test\r\n'),('whitespace header name','X : test\r\n'),('duplicate host','Host: duplicate\r\n'),('null header name','X\x00: test\r\n')]:
        check(name,req(upload,'POST',h),400)
    check('unsupported expectation',req(upload,'POST','Expect: never\r\nContent-Length: 5\r\n'),417)
    check('upload length required',req(upload,'POST'),411)
    check('JSON size limit',req('/api/localsend/v2/prepare-upload','POST','Content-Length: 1048577\r\n'),413)
    for name,body in [('invalid chunk size',b'g\r\n'),('negative chunk',b'-5\r\n'),('overflow chunk',b'8000000000000000\r\n'),('bad chunk CRLF',b'5\r\nhellox\r\n0\r\n\r\n'),('forbidden trailer',b'5\r\nhello\r\n0\r\nContent-Length: 5\r\n\r\n')]:
        check(name,req(upload,'POST','Transfer-Encoding: chunked\r\n',body),400)
    check('oversized streamed chunk rejected',req(upload,'POST','Transfer-Encoding: chunked\r\n',b'6\r\nhello!\r\n0\r\n\r\n'),422)
    check('short declared body rejected at finish',req(upload,'POST','Content-Length: 4\r\n',b'hell'),422)
    check('pipelined extra input rejected',req(upload,'POST','Content-Length: 5\r\n',b'helloGET / HTTP/1.1\r\n\r\n'),400)
    large=b'a'*200000
    check('large fixed body streams within 64KiB',req('/api/localsend/v2/upload?token=ok&size=200000','POST','Content-Length: 200000\r\n',large),200)
    for repeat in range(10):
        check('repeated 200KB streaming %d'%repeat,req('/api/localsend/v2/upload?token=ok&size=200000','POST','Content-Length: 200000\r\n',large),200)
    with connect() as sock:
        fragmented=req(upload,'POST','Transfer-Encoding: chunked\r\n',b'2\r\nhe\r\n3\r\nllo\r\n0\r\n\r\n')
        for offset in range(0,len(fragmented),3): sock.sendall(fragmented[offset:offset+3])
        response=sock.recv(4096)
        assert response.startswith(b'HTTP/1.1 200'),response
    print('PASS fragmented request and chunk framing',flush=True)
    # A clean TLS close before declared payload end must abort, not commit.
    before=json.loads(exchange(req()).split(b'\r\n\r\n')[1])
    with connect() as s:
        s.sendall(req(upload,'POST','Content-Length: 5\r\n',b'he'))
    time.sleep(.1)
    after=json.loads(exchange(req()).split(b'\r\n\r\n')[1])
    assert after['aborted']==before['aborted']+1 and after['finished']==before['finished'],(before,after)
    assert 0 < after['maxBlock'] <= 65536,after
    print('PASS truncated upload aborts without commit',flush=True)
    no_cert=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT); no_cert.check_hostname=False; no_cert.verify_mode=ssl.CERT_NONE
    no_cert.minimum_version=no_cert.maximum_version=ssl.TLSVersion.TLSv1_2
    try:
        with no_cert.wrap_socket(socket.create_connection(('127.0.0.1',port)),server_hostname='localhost') as s:
            s.sendall(req()); data=s.recv(4096)
            assert not data.startswith(b'HTTP/1.1 200'), data
    except (ssl.SSLError,ConnectionError): pass
    print('PASS client certificate required',flush=True)
    tls13=ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    tls13.check_hostname=False; tls13.verify_mode=ssl.CERT_NONE
    tls13.minimum_version=tls13.maximum_version=ssl.TLSVersion.TLSv1_3
    tls13.load_cert_chain(root/'client.crt',root/'client.key')
    try:
        with tls13.wrap_socket(socket.create_connection(('127.0.0.1',port),timeout=5),server_hostname='localhost') as s:
            raise AssertionError('TLS 1.3 connection succeeded despite TLS 1.2 policy')
    except (ssl.SSLError, ConnectionError):
        pass
    print('PASS configured TLS 1.2 ceiling enforced',flush=True)
    before=json.loads(exchange(req()).split(b'\r\n\r\n')[1])
    with connect() as sock:
        sock.sendall(req('/await-approval'))
        time.sleep(.03)
    time.sleep(.1)
    after=json.loads(exchange(req()).split(b'\r\n\r\n')[1])
    assert after['disconnects']==before['disconnects']+1,(before,after)
    print('PASS pending approval detects sender disconnect',flush=True)
    before=after
    with connect() as sock:
        sock.sendall(req('/await-approval'))
        time.sleep(.03)
        try:
            # unwrap sends close_notify; server's approval poll must observe it.
            raw=sock.unwrap()
            raw.close()
        except (ssl.SSLError, ConnectionError):
            pass
    time.sleep(.1)
    after=json.loads(exchange(req()).split(b'\r\n\r\n')[1])
    assert after['disconnects']==before['disconnects']+1,(before,after)
    print('PASS pending approval detects TLS close_notify',flush=True)
    idle=[connect(False) for _ in range(8)]
    extra=connect(False)
    assert extra.recv(1)==b''
    extra.close()
    for sock in idle: sock.close()
    time.sleep(.1)
    print('PASS eight-connection limit enforced',flush=True)
    idle=[connect(False) for _ in range(2)]
    with connect() as sock:
        sock.sendall(req('/invalidate'))
        assert sock.recv(4096)==b''
    for sock in idle:
        assert sock.recv(4096)==b''
        sock.close()
    print('PASS invalidate interrupts active sockets',flush=True)
    print('ALL TRANSPORT CHECKS PASSED',flush=True)
finally:
    p.terminate()
    try: p.wait(timeout=5)
    except subprocess.TimeoutExpired: p.kill()
    print('harness exit',p.returncode, p.stderr.read())
