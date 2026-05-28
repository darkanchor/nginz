async function probe(r) {
  const reply = await r.subrequest('/protected-sub-inner');
  r.return(200, String(reply.status));
}

async function probe_preaccess(r) {
  const auth = r.headersIn.Authorization;
  const token = auth && auth.startsWith('Bearer ') ? auth.slice(7) : '';
  const reply = await r.subrequest('/protected-sub-inner-preaccess', token ? `token=${encodeURIComponent(token)}` : '');
  r.return(200, String(reply.status));
}

export default { probe, probe_preaccess };
