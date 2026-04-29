async function probe(r) {
  const reply = await r.subrequest('/protected-sub-inner');
  r.return(200, String(reply.status));
}

export default { probe };
