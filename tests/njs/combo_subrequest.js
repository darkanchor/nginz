// Combo subrequest handlers — njs + redis + pgrest ecosystem demos

// ── Existing combos ────────────────────────────────────────────────────

async function redis_write_then_read(r) {
    var value = r.requestText || r.args.value || 'combo-value';
    var setReply = await r.subrequest('/_redis/combo_set', { method: 'POST', body: value });
    var getReply = await r.subrequest('/_redis/combo_get');
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        set: setReply.status === 200 ? JSON.parse(setReply.responseText) : null,
        get: getReply.status === 200 ? JSON.parse(getReply.responseText) : null,
    }));
}

async function redis_incr_twice(r) {
    var key = r.args.key || 'incr-combo';
    var r1 = await r.subrequest('/_redis/incr/' + key, { method: 'POST' });
    var r2 = await r.subrequest('/_redis/incr/' + key, { method: 'POST' });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        first: JSON.parse(r1.responseText).value,
        second: JSON.parse(r2.responseText).value,
    }));
}

async function redis_and_pgrest(r) {
    var redisKey = r.args.rkey || 'cached-users';
    var [redisReply, pgReply] = await Promise.all([
        r.subrequest('/_redis/get/' + redisKey),
        r.subrequest('/_pgrest/api/users'),
    ]);
    var redisData = redisReply.status === 200 ? JSON.parse(redisReply.responseText) : null;
    var pgData = pgReply.status === 200 ? JSON.parse(pgReply.responseText) : null;
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        redis_value: redisData ? redisData.value : null,
        pgrest_user_count: pgData ? pgData.length : 0,
    }));
}

async function redis_check_then_pgrest(r) {
    var key = r.args.key || 'cached-users';
    var redisReply = await r.subrequest('/_redis/get/' + key);
    if (redisReply.status === 200) {
        var d = JSON.parse(redisReply.responseText);
        if (d.value !== null) {
            r.headersOut['Content-Type'] = 'application/json';
            r.headersOut['X-Cache'] = 'HIT';
            r.return(200, JSON.stringify({ source: 'redis', cached: true, data: d.value }));
            return;
        }
    }
    var pgReply = await r.subrequest('/_pgrest/api/users');
    r.headersOut['Content-Type'] = 'application/json';
    r.headersOut['X-Cache'] = 'MISS';
    r.return(200, JSON.stringify({
        source: 'pgrest', cached: false,
        user_count: pgReply.status === 200 ? JSON.parse(pgReply.responseText).length : 0,
    }));
}

async function read_through_cache(r) {
    var redisKey = r.args.key || 'cached-users';
    var redisReply = await r.subrequest('/_redis/get/' + redisKey);
    var d = redisReply.status === 200 ? JSON.parse(redisReply.responseText) : null;
    if (d && d.value !== null) {
        r.headersOut['Content-Type'] = 'application/json';
        r.headersOut['X-Cache'] = 'HIT';
        r.return(200, JSON.stringify({ source: 'redis', data: d.value }));
        return;
    }
    var pgReply = await r.subrequest('/_pgrest/api/users');
    if (pgReply.status !== 200) { r.return(pgReply.status, pgReply.responseText); return; }
    var users = pgReply.responseText;
    await r.subrequest('/_redis/cache_set', { method: 'POST', body: users });
    r.headersOut['Content-Type'] = 'application/json';
    r.headersOut['X-Cache'] = 'MISS';
    r.return(200, JSON.stringify({ source: 'pgrest', cached: true, user_count: JSON.parse(users).length }));
}

async function counter_and_data(r) {
    var ckey = r.args.ckey || 'api-hits';
    var incrReply = await r.subrequest('/_redis/incr/' + ckey, { method: 'POST' });
    var pgReply = await r.subrequest('/_pgrest/api/users');
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        hit_count: incrReply.status === 200 ? JSON.parse(incrReply.responseText).value : -1,
        user_count: pgReply.status === 200 ? JSON.parse(pgReply.responseText).length : 0,
    }));
}

// ── 1. TTL-aware refresh ──────────────────────────────────────────────

async function ttl_aware_refresh(r) {
    var key = r.args.key || 'ttl-cached';
    // Step 1: GET value
    var getReply = await r.subrequest('/_redis/get/' + key);
    var getData = getReply.status === 200 ? JSON.parse(getReply.responseText) : null;
    // Step 2: TTL
    var ttlReply = await r.subrequest('/_redis/ttl/' + key);
    var ttlVal = ttlReply.status === 200 ? JSON.parse(ttlReply.responseText).value : -2;

    var refreshed = false;
    if (ttlVal >= 0 && ttlVal <= 10) {
        // Expiring soon — refresh from PGrest
        var pgReply = await r.subrequest('/_pgrest/api/users');
        if (pgReply.status === 200) {
            // Re-cache (using prefix-matching key)
            await r.subrequest('/_redis/set/' + key, { method: 'POST', body: pgReply.responseText });
            refreshed = true;
        }
    }

    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        value: getData ? getData.value : null,
        ttl: ttlVal,
        refreshed: refreshed,
    }));
}

// ── 2. DEL + refresh ──────────────────────────────────────────────────

async function del_and_refresh(r) {
    var key = r.args.key || 'stale-cache';
    // Step 1: DEL old cache
    var delReply = await r.subrequest('/_redis/del/' + key, { method: 'POST' });
    // Step 2: PGrest fetch fresh data
    var pgReply = await r.subrequest('/_pgrest/api/users');
    // Step 3: SET new cache
    var users = pgReply.status === 200 ? pgReply.responseText : '[]';
    await r.subrequest('/_redis/set/' + key, { method: 'POST', body: users });

    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        deleted: delReply.status === 200 ? JSON.parse(delReply.responseText).value : 0,
        user_count: JSON.parse(users).length,
    }));
}

// ── 3. DECR rate gate ─────────────────────────────────────────────────

async function decr_rate_gate(r) {
    var key = r.args.key || 'rate-limit';
    // Step 1: DECR the counter
    var decrReply = await r.subrequest('/_redis/decr/' + key, { method: 'POST' });
    var remaining = decrReply.status === 200 ? JSON.parse(decrReply.responseText).value : -1;

    if (remaining < 0) {
        r.headersOut['Content-Type'] = 'application/json';
        r.return(429, JSON.stringify({ error: 'rate_limited', remaining: remaining }));
        return;
    }

    // Rate limit OK — fetch from PGrest
    var pgReply = await r.subrequest('/_pgrest/api/users');
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        allowed: true,
        remaining: remaining,
        user_count: pgReply.status === 200 ? JSON.parse(pgReply.responseText).length : 0,
    }));
}

// ── 4. Hash config → PGrest query ─────────────────────────────────────

async function hash_config_query(r) {
    var hkey = r.args.hkey || 'query-config';
    // Step 1: HGET the config
    var hgetReply = await r.subrequest('/_redis/hget/' + hkey + '?field=select');
    var selectField = null;
    if (hgetReply.status === 200) {
        var hdata = JSON.parse(hgetReply.responseText);
        selectField = hdata.value; // e.g. "id,name" or null
    }

    // Step 2: Query PGrest with the config-driven select
    var uri = '/_pgrest/api/users';
    if (selectField) {
        uri += '?select=' + encodeURIComponent(selectField);
    }
    var pgReply = await r.subrequest(uri);

    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        config_select: selectField,
        result: pgReply.status === 200 ? JSON.parse(pgReply.responseText) : [],
    }));
}

// ── 5. MGET batch + PGrest fallback ───────────────────────────────────

async function mget_fallback(r) {
    var keys = r.args.keys || 'm1,m2,m3';
    // Step 1: MGET from Redis
    var mgetReply = await r.subrequest('/_redis/mget?keys=' + keys);
    var mgetData = mgetReply.status === 200 ? JSON.parse(mgetReply.responseText) : null;

    // Step 2: For each null, we'd normally query PGrest. For demo, count misses.
    var hits = 0;
    var misses = 0;
    if (mgetData && mgetData.values) {
        for (var i = 0; i < mgetData.values.length; i++) {
            if (mgetData.values[i] !== null) hits++; else misses++;
        }
    }

    // Step 3: Fetch PGrest for the misses (simplified: just fetch all)
    var pgReply = null;
    if (misses > 0) {
        pgReply = await r.subrequest('/_pgrest/api/users');
    }

    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        mget_values: mgetData ? mgetData.values : [],
        cache_hits: hits,
        cache_misses: misses,
        pgrest_fallback: pgReply !== null,
        pgrest_count: pgReply && pgReply.status === 200 ? JSON.parse(pgReply.responseText).length : 0,
    }));
}

// ── 6. EXISTS guard → PGrest write ────────────────────────────────────

async function exists_guard(r) {
    var key = r.args.key || 'guard-key';
    // Step 1: EXISTS check
    var existsReply = await r.subrequest('/_redis/exists/' + key);
    var exists = existsReply.status === 200 ? JSON.parse(existsReply.responseText).value : 0;

    if (exists === 0) {
        r.headersOut['Content-Type'] = 'application/json';
        r.return(403, JSON.stringify({ error: 'guard_key_missing', key: '_redis/exists/' + key }));
        return;
    }

    // Guard passed — allow PGrest operation
    var body = r.requestText || '{"name":"Guard-User","email":"guard@test.com"}';
    var pgReply = await r.subrequest('/_pgrest/api/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: body,
    });

    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        guard_ok: true,
        post_status: pgReply.status,
    }));
}

// ── 7. PING health → PGrest ───────────────────────────────────────────

async function ping_then_pgrest(r) {
    // Step 1: PING Redis
    var pingReply = await r.subrequest('/_redis/ping');
    var redisOk = pingReply.status === 200 && JSON.parse(pingReply.responseText).ok === true;

    if (!redisOk) {
        r.return(503, JSON.stringify({ error: 'redis_unavailable' }));
        return;
    }

    // Redis healthy — query PGrest
    var pgReply = await r.subrequest('/_pgrest/api/users');

    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        redis_healthy: true,
        user_count: pgReply.status === 200 ? JSON.parse(pgReply.responseText).length : 0,
    }));
}

// ── 8. STRLEN validation → refresh if short ───────────────────────────

async function strlen_refresh(r) {
    var key = r.args.key || 'str-cached';
    // Step 1: STRLEN on cached value
    var strlenReply = await r.subrequest('/_redis/strlen/' + key);
    var length = strlenReply.status === 200 ? JSON.parse(strlenReply.responseText).value : 0;

    var refreshed = false;
    if (length < 10) {
        // Too short — refresh from PGrest and write to shared-key location
        var pgReply = await r.subrequest('/_pgrest/api/users');
        if (pgReply.status === 200) {
            await r.subrequest('/_redis/str_set', { method: 'POST', body: pgReply.responseText });
            refreshed = true;
        }
    }

    // Read from shared-key location
    var getReply = await r.subrequest('/_redis/str_get');
    var value = getReply.status === 200 ? JSON.parse(getReply.responseText).value : null;

    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        strlen: length,
        refreshed: refreshed,
        value: value,
    }));
}

export default {
    redis_write_then_read,
    redis_incr_twice,
    redis_and_pgrest,
    redis_check_then_pgrest,
    read_through_cache,
    counter_and_data,
    ttl_aware_refresh,
    del_and_refresh,
    decr_rate_gate,
    hash_config_query,
    mget_fallback,
    exists_guard,
    ping_then_pgrest,
    strlen_refresh,
};
