import { describe, test, expect, beforeAll, afterAll, beforeEach } from 'bun:test';
import { createHmac } from 'node:crypto';
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import http from 'node:http';
import net from 'node:net';
import tls from 'node:tls';
import { startNginz, stopNginz, cleanupRuntime, createHTTPMock, reloadNginz, TEST_URL } from '../harness.js';

const TOKEN = 'xpay-test-token+/=&?# 空格';
const LIVE_KEY = 'xpay-test-live-key';
const SANDBOX_KEY = 'xpay-test-sandbox-key';
const BODY = '{ "env": 0, "order_id":"单\\u00261", "openid":"test-openid" }';
let mock;
const post = (path, body = BODY, extra = {}) => fetch(TEST_URL + path, {
    method: 'POST', body, ...extra,
    headers: { Connection: 'close', ...extra.headers },
});
async function call(body = BODY, target = '/xpay/query_order') {
    const res = await post('/call?target=' + encodeURIComponent(target), body);
    expect(res.status).toBe(200);
    return res.json();
}
function expectedSig(key, path, body) {
    return createHmac('sha256', key).update(path + '&' + body).digest('hex');
}
function chunkedPost(path, body) {
    return new Promise((resolve, reject) => {
        const req = http.request(TEST_URL + path, { method: 'POST', headers: {
            'Transfer-Encoding': 'chunked', Connection: 'close',
        } }, (res) => {
            const parts = [];
            res.on('data', (part) => parts.push(part));
            res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(parts).toString() }));
        });
        req.on('error', reject);
        req.write(body.slice(0, 10));
        setTimeout(() => req.end(body.slice(10)), 10);
    });
}
async function rawGateway(chunks, fn) {
    let count = 0;
    const sockets = new Set();
    const server = net.createServer((socket) => {
        sockets.add(socket);
        socket.on('close', () => sockets.delete(socket));
        socket.on('error', () => {});
        socket.once('data', async () => {
            count++;
            for (const chunk of chunks) {
                socket.write(chunk);
                await Bun.sleep(5);
            }
            socket.end();
        });
    });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(19005, '127.0.0.1', resolve); });
    try { await fn(() => count); } finally {
        for (const socket of sockets) socket.destroy();
        await new Promise((resolve) => server.close(resolve));
    }
}

describe('XPay pass-through', () => {
    beforeAll(async () => {
        mock = createHTTPMock(19001);
        await startNginz('tests/xpay/nginx.conf', 'xpay');
    });
    beforeEach(() => mock.reset());
    afterAll(async () => {
        await stopNginz();
        mock.stop();
        const log = readFileSync('tests/xpay/runtime/logs/error.log', 'utf8');
        expect(log).not.toMatch(/\[alert\]|\[crit\]|header already sent|pending events while closing request|signal 11/);
        cleanupRuntime('xpay');
    });

    test('signs exact UTF-8 bytes, injects one escaped token, strips caller headers', async () => {
        let observed;
        mock.post('/xpay/query_order', async (req, url) => {
            observed = { headers: Object.fromEntries(req.headers), url, body: await req.text() };
            return { body: '{"errcode":0,"order":{"status":2}}' };
        });
        const res = await post('/xpay/query_order', BODY, { headers: {
            Authorization: 'forged', Cookie: 'session=private', 'Wechatpay-Serial': 'forged',
        } });
        expect(res.status).toBe(200);
        expect(await res.json()).toEqual({ errcode: 0, order: { status: 2 } });
        expect(observed.body).toBe(BODY);
        expect([...observed.url.searchParams]).toEqual([
            ['access_token', TOKEN], ['pay_sig', expectedSig(LIVE_KEY, '/xpay/query_order', BODY)],
        ]);
        expect(observed.headers.authorization).toBeUndefined();
        expect(observed.headers.cookie).toBeUndefined();
        expect(observed.headers['wechatpay-serial']).toBeUndefined();
        expect(observed.headers.host).toBe('127.0.0.1:19001');
    });

    test('accepts escaped environment keys and preserves JSON whitespace and number spellings', async () => {
        const body = ' \t{"e\\u006ev":0,"Env":1,"data":[1.25e2,-0,1e1000],"text":"中文"}\r\n';
        mock.post('/xpay/query_order', async (req, url) => {
            expect(await req.text()).toBe(body);
            expect(url.searchParams.get('pay_sig')).toBe(expectedSig(LIVE_KEY, '/xpay/query_order', body));
            return { body: '{}' };
        });
        expect((await post('/xpay/query_order', body)).status).toBe(200);
    });

    test('selects sandbox only at an explicitly configured sandbox location', async () => {
        const body = '{"env":1}';
        mock.post('/xpay/sandbox', (req, url) => {
            expect(url.searchParams.get('pay_sig')).toBe(expectedSig(SANDBOX_KEY, '/xpay/sandbox', body));
            return { body: '{}' };
        });
        expect((await post('/xpay/sandbox', body)).status).toBe(200);
        expect((await post('/xpay/sandbox', BODY)).status).toBe(400);
        expect((await post('/xpay/query_order', body)).status).toBe(400);
        expect(mock.requestCount).toBe(1);
    });

    test('token-only delivery does not add pay_sig', async () => {
        mock.post('/xpay/notify_provide_goods', (req, url) => {
            expect([...url.searchParams]).toEqual([['access_token', TOKEN]]);
            return { status: 200, body: '{"errcode":0}' };
        });
        expect((await post('/xpay/notify_provide_goods')).status).toBe(200);
    });

    test('preserves business errors and HTTP status through an audited njs subrequest', async () => {
        for (const status of [200, 400, 429, 503]) {
            const body = '{"errcode":40014,"errmsg":"invalid token"}';
            mock.post('/xpay/query_order', () => ({ status, body }));
            const result = await call();
            expect(result.status).toBe(status);
            expect(result.body).toBe(body);
            expect(result.response).toBe(body);
            expect(result.protocol).toBe('xpay');
            expect(result.transport).toBe('complete');
            expect(result.verification).toBe('unverified');
            expect(result.request).toContain('POST /xpay/query_order HTTP/1.1\r\n');
            expect(result.request).toContain('X-Wechatpay-Auth: appkey');
            expect(result.request.endsWith('\r\n\r\n' + BODY)).toBe(true);
            expect(result.request).not.toMatch(/access_token|pay_sig|xpay-test-token|xpay-test-live-key/);
        }
        expect(mock.requestCount).toBe(4);
    });

    test('fails closed when audit rejects, including a suspended subrequest', async () => {
        const body = '{"env":0,"order_id":"deny-audit"}';
        expect((await call(body)).status).toBe(503);
        expect((await post('/xpay/query_order', body)).status).toBe(503);
        expect(mock.requestCount).toBe(0);
        expect((await post('/xpay/query_order')).status).toBe(200);
    });

    test('rejects missing tokens, unsupported methods, incoming query credentials and malformed bodies', async () => {
        expect((await post('/xpay/no_token')).status).toBe(500);
        expect((await fetch(TEST_URL + '/xpay/query_order')).status).toBe(405);
        for (const query of ['access_token=forged', 'pay_sig=x&pay_sig=y', '%73ignature=x', 'unknown=x']) {
            expect((await post('/xpay/query_order?' + query)).status).toBe(400);
        }
        for (const body of ['', '{}', '[]', '{"env":0}garbage', '{"env":0.0}', '{"env":"0"}',
            '{"env":0,"env":1}', '{"env":0,"e\\u006ev":0}', '{"env":0,"pay_sig":"forged"}',
            '{"env":0,"access_token":"forged"}', '{"env":0,"signature":"forged"}',
            '{"env":-0}', '{"env":1e0}', '{"env":00}', '{"env":0.}',
            '{"env":0}\0', '{"env":0}\0garbage', '{"env":0,"Env":1,"pay_\\u0073ig":"forged"}',
            '{"env":0,"nested":{"x":1,"x":2}}', '{"env":0,"x":"raw\nnewline"}',
            '{"env":0,"x":"\\u0000"}', '{"env":0,"x":"\\uXXXX"}', '{"env":0,"x":01}']) {
            expect((await post('/xpay/query_order', body)).status).toBe(400);
        }
        expect(mock.requestCount).toBe(0);
    });

    test('completes rejected njs payment subrequests without terminating the parent', async () => {
        expect((await call('{"env":1}')).status).toBe(400);
        expect((await call('')).status).toBe(400);
        expect((await call(BODY, '/xpay/no_token')).status).toBe(500);
        expect(mock.requestCount).toBe(0);
    });

    test('signs catalog endpoints with the same exact-body protocol', async () => {
        // Endpoint selection is application configuration, not a hard-coded
        // business catalog inside the native module.
        mock.post('/xpay/start_upload_goods', async (req, url) => {
            const body = await req.text();
            expect(url.searchParams.get('pay_sig')).toBe(expectedSig(LIVE_KEY, url.pathname, body));
            return { body: '{"errcode":0}' };
        });
        const body = '{"env":0,"goods":[{"product_id":"carve_month","price":100}]}';
        expect((await post('/xpay/start_upload_goods', body)).status).toBe(200);
    });

    test('signs file-buffered and chunked request bodies without rewriting them', async () => {
        const body = JSON.stringify({ env: 0, text: '中文'.repeat(2000) });
        for (const path of ['/xpay/spill', '/xpay/query_order']) {
            mock.post(path, async (req, url) => {
                expect(await req.text()).toBe(body);
                expect(url.searchParams.get('pay_sig')).toBe(expectedSig(LIVE_KEY, path, body));
                return { body: '{"ok":true}' };
            });
        }
        expect((await post('/xpay/spill', body)).status).toBe(200);
        expect((await chunkedPost('/xpay/query_order', body)).status).toBe(200);
    });

    test('bounds request and response bodies', async () => {
        const body = JSON.stringify({ env: 0, text: 'x'.repeat(100) });
        expect((await post('/xpay/bounded', body)).status).toBe(413);
        expect((await chunkedPost('/xpay/bounded', body)).status).toBe(413);
        expect(mock.requestCount).toBe(0);
        mock.post('/xpay/bounded', () => ({ body: 'x'.repeat(100) }));
        expect((await post('/xpay/bounded', '{"env":0}')).status).toBe(502);
    });

    test('decodes actual chunked wire responses across packet boundaries', async () => {
        await rawGateway(['HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: application/json\r\n\r\n',
            '7\r', '\n{"errco\r\n', '6;extension=yes\r\nde":0}', '\r\n0\r\nX-Trailer: ok\r\n\r\n'], async () => {
            const result = await call('{"env":0}', '/xpay/raw');
            expect(result.status).toBe(200);
            expect(result.body).toBe('{"errcode":0}');
            expect(result.transport).toBe('complete');
        });
    });

    test('handles empty upstream responses', async () => {
        await rawGateway(['HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n'], async () => {
            const result = await call('{"env":0}', '/xpay/raw');
            expect(result.status).toBe(204);
            expect(result.body).toBe('');
            expect(result.transport).toBe('complete');
        });
    });

    test('rejects an untrusted TLS peer before sending payment credentials', async () => {
        const dir = mkdtempSync(join(tmpdir(), 'nginz-xpay-tls-'));
        try {
            const gen = Bun.spawnSync(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                '-keyout', join(dir, 'key.pem'), '-out', join(dir, 'cert.pem'),
                '-days', '1', '-subj', '/CN=localhost']);
            expect(gen.exitCode).toBe(0);
            let requests = 0;
            const server = tls.createServer({ key: readFileSync(join(dir, 'key.pem')), cert: readFileSync(join(dir, 'cert.pem')) },
                (socket) => socket.on('data', () => requests++));
            server.on('tlsClientError', () => {});
            await new Promise((resolve) => server.listen(19005, '127.0.0.1', resolve));
            try {
                const result = await call('{"env":0}', '/xpay/tls');
                expect(result.status).toBe(502);
                expect(result.transport).toBe('incomplete');
                expect(requests).toBe(0);
            } finally { await new Promise((resolve) => server.close(resolve)); }
        } finally { rmSync(dir, { recursive: true, force: true }); }
    });

    test('survives client cancellation while reading an upstream response', async () => {
        await rawGateway(['HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial'], async () => {
            const abort = new AbortController();
            const request = post('/call?target=%2Fxpay%2Fraw', '{"env":0}', { signal: abort.signal });
            setTimeout(() => abort.abort(), 2);
            await request.catch(() => {});
            await Bun.sleep(50);
        });
        expect((await post('/xpay/query_order')).status).toBe(200);
    });

    test('upstream read timeout completes the parent request without retry', async () => {
        let count = 0;
        const sockets = new Set();
        const server = net.createServer((socket) => {
            sockets.add(socket);
            socket.on('error', () => {});
            socket.on('close', () => sockets.delete(socket));
            socket.once('data', () => { count++; });
        });
        await new Promise((resolve) => server.listen(19005, '127.0.0.1', resolve));
        try {
            const result = await call('{"env":0}', '/xpay/raw');
            expect(result.status).toBe(502);
            expect(result.transport).toBe('incomplete');
            expect(count).toBe(1);
        } finally {
            for (const socket of sockets) socket.destroy();
            await new Promise((resolve) => server.close(resolve));
        }
    }, 70000);

    test('fails incomplete, malformed and oversized framing without replay', async () => {
        for (const wire of [
            'HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\nshort',
            'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nshort\r\n',
            'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nnope\r\n',
            'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n200\r\n' + 'x'.repeat(512) + '\r\n0\r\n\r\n',
        ]) {
            await rawGateway([wire], async (count) => {
                const result = await call('{"env":0}', '/xpay/raw');
                expect(result.status).toBe(502);
                expect(result.transport).toBe('incomplete');
                expect(result.verification).toBe('unverified');
                expect(count()).toBe(1);
            });
        }
    });
});

describe('XPay configuration', () => {
    const binary = resolve('zig-out/bin/nginz');
    const key = resolve('tests/xpay/fixtures/live.key');
    let dir;
    beforeAll(() => { dir = mkdtempSync(join(tmpdir(), 'nginz-xpay-config-')); });
    afterAll(() => rmSync(dir, { recursive: true, force: true }));
    function check(directives, global = '') {
        const config = join(dir, 'nginx.conf');
        writeFileSync(config, `error_log stderr; pid ${dir}/nginx.pid;
            events {} http { access_log off;
            client_body_temp_path client_temp; proxy_temp_path proxy_temp;
            fastcgi_temp_path fastcgi_temp; uwsgi_temp_path uwsgi_temp; scgi_temp_path scgi_temp;
            variables_hash_max_size 2048; variables_hash_bucket_size 128; ${global}
            server { listen 18888; location /xpay/query_order { ${directives} } } }`);
        const proc = Bun.spawnSync([binary, '-t', '-e', 'stderr', '-p', dir, '-c', config]);
        return { code: proc.exitCode, output: proc.stderr.toString() };
    }
    const base = `wechatpay_xpay_proxy_pass https://api.weixin.qq.com;
        wechatpay_xpay_access_token private-test-token; wechatpay_xpay_auth appkey;
        wechatpay_xpay_live_key_file ${key};`;
    test('works without API v3 credentials and token-only mode needs no AppKey', () => {
        expect(check(base).output).toContain("test is successful");
        expect(check('wechatpay_xpay_proxy_pass https://api.weixin.qq.com; wechatpay_xpay_access_token test; wechatpay_xpay_auth token;').output).toContain('test is successful');
    });
    test('fails closed for missing credentials, invalid policies, mixed modes and unsafe origins', () => {
        for (const [config, message] of [
            [base.replace(`wechatpay_xpay_live_key_file ${key};`, ''), 'selected AppKey is missing'],
            [base + 'wechatpay_xpay_env 1;', 'selected AppKey is missing'],
            [base + 'wechatpay_xpay_env 2;', 'must be 0 or 1'],
            [base.replace('wechatpay_xpay_access_token private-test-token;', ''), 'requires access_token'],
            [base.replace('wechatpay_xpay_auth appkey;', ''), 'must be appkey or token'],
            [base.replace('wechatpay_xpay_auth appkey;', 'wechatpay_xpay_auth invalid;'), 'must be appkey or token'],
            [base + 'wechatpay_proxy_pass https://api.mch.weixin.qq.com;', 'cannot be combined'],
            [base + 'wechatpay_access;', 'cannot be combined'],
            [base.replace('https://api.weixin.qq.com', 'http://api.weixin.qq.com'), 'must use https'],
            [base.replace('https://api.weixin.qq.com', 'https://api.weixin.qq.com/xpay/query_order'), 'without path'],
            [base.replace('https://api.weixin.qq.com', 'https://user@api.weixin.qq.com'), 'without path'],
            [base.replace('https://api.weixin.qq.com', 'https://api.weixin.qq.com:999999999999'), 'without path'],
        ]) {
            const result = check(config);
            // The nginz Zig entrypoint currently discards nginx_main's return code.
            expect(result.output, config).toContain("test failed");
            expect(result.output).toContain(message);
        }
    });
});

describe('XPay key rotation', () => {
    let dir;
    beforeAll(async () => {
        dir = mkdtempSync(join(tmpdir(), 'nginz-xpay-rotation-'));
        writeFileSync(join(dir, 'live.key'), 'before-reload');
        writeFileSync(join(dir, 'nginx.conf'), `daemon off; error_log logs/error.log notice;
            pid logs/nginx.pid; events { worker_connections 64; }
            http { access_log off; client_body_temp_path client_temp;
                proxy_temp_path proxy_temp; fastcgi_temp_path fastcgi_temp;
                uwsgi_temp_path uwsgi_temp; scgi_temp_path scgi_temp;
                wechatpay_allow_insecure_http on;
                wechatpay_xpay_access_token rotation-token;
                wechatpay_xpay_auth appkey;
                wechatpay_xpay_live_key_file ${join(dir, 'live.key')};
                server { listen 8888; location /xpay/query_order {
                    wechatpay_xpay_proxy_pass http://127.0.0.1:19001;
                } }
            }`);
        mock = createHTTPMock(19001);
        await startNginz(join(dir, 'nginx.conf'), 'xpay-rotation');
    });
    afterAll(async () => {
        await stopNginz(); mock.stop(); cleanupRuntime('xpay-rotation');
        rmSync(dir, { recursive: true, force: true });
    });
    test('loads changed keys on nginx reload', async () => {
        mock.post('/xpay/query_order', async (req, url) => ({
            body: JSON.stringify({ signature: url.searchParams.get('pay_sig') }),
        }));
        const before = expectedSig('before-reload', '/xpay/query_order', BODY);
        const after = expectedSig('after-reload', '/xpay/query_order', BODY);
        expect((await (await post('/xpay/query_order')).json()).signature).toBe(before);
        writeFileSync(join(dir, 'live.key'), 'after-reload');
        expect((await (await post('/xpay/query_order')).json()).signature).toBe(before);
        const logPath = 'tests/xpay-rotation/runtime/logs/error.log';
        const oldWorkers = [...readFileSync(logPath, 'utf8').matchAll(/start worker process (\d+)/g)].map((m) => m[1]);
        expect(oldWorkers.length).toBeGreaterThan(0);
        await reloadNginz();
        // Reload is asynchronous. Wait for the old generation to drain before
        // asserting that every new connection uses the replacement key.
        const deadline = Date.now() + 3000;
        while (Date.now() < deadline) {
            const log = readFileSync(logPath, 'utf8');
            if (oldWorkers.every((pid) => log.includes(`worker process ${pid} exited with code 0`))) break;
            await Bun.sleep(25);
        }
        const log = readFileSync(logPath, 'utf8');
        for (const pid of oldWorkers) expect(log).toContain(`worker process ${pid} exited with code 0`);
        expect((await (await post('/xpay/query_order')).json()).signature).toBe(after);
    });
});
