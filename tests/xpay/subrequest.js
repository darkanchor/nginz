function token(r) {
    return 'xpay-test-token+/=&?# 空格';
}
async function query(r) {
    const reply = await r.subrequest(r.args.target || '/xpay/query_order', {
        method: 'POST', body: r.requestText || '',
    });
    r.return(200, JSON.stringify({
        status: reply.status,
        body: reply.responseText,
        protocol: reply.variables.wechatpay_protocol,
        transport: reply.variables.wechatpay_transport,
        verification: reply.variables.wechatpay_verification,
        request: reply.variables.wechatpay_request,
        response: reply.variables.wechatpay_response,
    }));
}
function audit(r) {
    const evidence = r.variables.wechatpay_request;
    r.warn('XPAY_AUDIT ' + JSON.stringify({
        protocol: r.variables.wechatpay_protocol, evidence,
    }));
    r.return(evidence.includes('deny-audit') ? 503 : 204);
}
export default { token, query, audit };
