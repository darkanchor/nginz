async function query(r) {
    const target = r.args.raw === '1' ? '/proxy-raw' : '/proxy';
    const reply = await r.subrequest(target, {
        method: 'POST',
        body: r.requestText || '',
    });
    r.headersOut['Content-Type'] = 'application/json';
    r.return(200, JSON.stringify({
        status: reply.status,
        verification: reply.variables.wechatpay_verification,
        body: reply.responseText,
    }));
}

export default { query };
