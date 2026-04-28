// pgrest subrequest helpers for njs — one operation per handler

async function pgrest_get_users(r) {
    var reply = await r.subrequest('/_pgrest/api/users');
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function pgrest_get_users_filtered(r) {
    var id = r.args.id || '1';
    var select = r.args.select || 'id,name';
    var reply = await r.subrequest('/_pgrest/api/users?id=eq.' + id + '&select=' + select);
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function pgrest_create_user(r) {
    var body = r.requestText || '{"name":"njs-user","email":"njs@test.com"}';
    var reply = await r.subrequest('/_pgrest/api/users', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: body,
    });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function pgrest_update_user(r) {
    var id = r.args.id || '1';
    var body = r.requestText || '{"name":"updated-via-njs"}';
    var reply = await r.subrequest('/_pgrest/api/users?id=eq.' + id, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: body,
    });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function pgrest_delete_user(r) {
    var id = r.args.id || '1';
    var reply = await r.subrequest('/_pgrest/api/users?id=eq.' + id, {
        method: 'DELETE',
    });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

async function pgrest_rpc(r) {
    var fn = r.args.fn || 'add_them';
    var a = r.args.a || '1';
    var b = r.args.b || '2';
    var reply = await r.subrequest('/_pgrest/rpc/' + fn, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ a: Number(a), b: Number(b) }),
    });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(reply.status, reply.responseText);
}

export default {
    pgrest_get_users,
    pgrest_get_users_filtered,
    pgrest_create_user,
    pgrest_update_user,
    pgrest_delete_user,
    pgrest_rpc,
};
