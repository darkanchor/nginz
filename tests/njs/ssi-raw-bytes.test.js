import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL, createPostgresMock, MOCK_PORTS } from "../harness.js";
import { connect } from "bun";

const MODULE = "njs";
let pgMock;

async function rawHttp(host, port, request) {
  return new Promise((resolve, reject) => {
    let buf = "";
    const socket = connect({
      hostname: host, port,
      socket: {
        data(sock, data) { buf += data.toString(); },
        open(sock) { sock.write(request); },
        close() { resolve(buf); },
        error(sock, e) { reject(e); },
      }
    });
    setTimeout(() => resolve(buf), 3000);
  });
}

describe("ssi raw bytes", () => {
  beforeAll(async () => {
    pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);
    pgMock.setQueryHandler(/users/i, (q) => {
      if (/SELECT.*count/i.test(q)) return { columns: ["count"], rows: [["3"]] };
      return { columns: ["id","name"], rows: [["1","Alice"],["2","Bob"],["3","Carol"]] };
    });
    pgMock.setQueryHandler(/pg_constraint|pg_class|pg_attribute|pg_namespace|pg_type|information_schema/i, () => ({ columns: ["dummy"], rows: [] }));
    pgMock.setQueryHandler(/^SET\s|^RESET\s/i, () => ({ columns: [], rows: [] }));
    await startNginz("tests/njs/ssi-pgrest.conf", MODULE);
  }, 30000);
  afterAll(async () => { await stopNginz(); cleanupRuntime(MODULE); pgMock?.stop(); });

  test("raw bytes of 3 SSI requests on one connection", async () => {
    // Send 3 requests pipelined (but wait for response in between)
    const port = parseInt(TEST_URL.split(":")[2] || "8888");
    const req = "GET /ssi/users HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    
    // Request 1
    const r1 = await rawHttp("localhost", port, req);
    console.log("=== Request 1 raw (first 200 chars) ===\n" + r1.substring(0, 200).replace(/\r/g, "\\r").replace(/\n/g, "\\n\n"));
    
    // Request 2 - wait a bit for keepalive to settle
    await new Promise(r => setTimeout(r, 100));
    const r2 = await rawHttp("localhost", port, req);
    console.log("=== Request 2 raw (first 200 chars) ===\n" + r2.substring(0, 200).replace(/\r/g, "\\r").replace(/\n/g, "\\n\n"));
    
    expect(r1).toContain("Alice");
    expect(r2).toContain("Alice");
  });
});
