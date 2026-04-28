// Redis subrequest helpers for njs — one operation per handler

async function redis_get(r) {
    var key = r.args.key || 'test-key';
    var reply = await r.subrequest('/_redis/get/' + key);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_set(r) {
    var key = r.args.key || 'default';
    var value = r.requestText || r.args.value || 'njs-value';
    var reply = await r.subrequest('/_redis/set/' + key, { method: 'POST', body: value });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_del(r) {
    var key = r.args.key || 'to-delete';
    var reply = await r.subrequest('/_redis/del/' + key, { method: 'POST' });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_incr(r) {
    var key = r.args.key || 'incr-counter';
    var reply = await r.subrequest('/_redis/incr/' + key, { method: 'POST' });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_decr(r) {
    var key = r.args.key || 'decr-counter';
    var reply = await r.subrequest('/_redis/decr/' + key, { method: 'POST' });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_exists(r) {
    var key = r.args.key || 'exists-key';
    var reply = await r.subrequest('/_redis/exists/' + key);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_ttl(r) {
    var key = r.args.key || 'ttl-key';
    var reply = await r.subrequest('/_redis/ttl/' + key);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_ping(r) {
    var reply = await r.subrequest('/_redis/ping');
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_strlen(r) {
    var key = r.args.key || 'str-key';
    var reply = await r.subrequest('/_redis/strlen/' + key);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_mget(r) {
    var keys = r.args.keys || 'a,b';
    var reply = await r.subrequest('/_redis/mget?keys=' + keys);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_parallel(r) {
    var key1 = r.args.k1 || 'p1';
    var key2 = r.args.k2 || 'p2';
    var [a, b] = await Promise.all([
        r.subrequest('/_redis/get/' + key1),
        r.subrequest('/_redis/get/' + key2),
    ]);
    var result = {
        k1: a.status === 200 ? JSON.parse(a.responseText) : null,
        k2: b.status === 200 ? JSON.parse(b.responseText) : null,
    };
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify(result));
}

async function redis_hget(r) {
    var key = r.args.key || 'hash-key';
    var field = r.args.field || 'name';
    var reply = await r.subrequest('/_redis/hget/' + key + '?field=' + field);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_hset(r) {
    var key = r.args.key || 'hash-key';
    var field = r.args.field || 'name';
    var value = r.requestText || r.args.value || 'njs-value';
    var reply = await r.subrequest('/_redis/hset/' + key + '?field=' + field, {
        method: 'POST',
        body: value,
    });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function redis_hdel(r) {
    var key = r.args.key || 'hash-key';
    var field = r.args.field || 'name';
    var reply = await r.subrequest('/_redis/hdel/' + key + '?field=' + field, {
        method: 'POST',
    });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

export default {
    redis_get,
    redis_set,
    redis_del,
    redis_incr,
    redis_decr,
    redis_exists,
    redis_ttl,
    redis_ping,
    redis_strlen,
    redis_mget,
    redis_parallel,
    redis_hget,
    redis_hset,
    redis_hdel,
};
