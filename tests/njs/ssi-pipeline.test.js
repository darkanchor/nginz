import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createPostgresMock,
  MOCK_PORTS,
  teardownModule,
  prepareMockPorts,
  testFetch,
} from "../harness.js";
import net from "net";

const MODULE = "njs";
let pgMock;

async function runKeepAlive(port) {
  return new Promise((resolve, reject) => {
    const sock = new net.Socket();
    const results = [];
    let buf = "";
    let reqCount = 0;
    const req = "GET /ssi/users HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n";
    
    function parseResponse(data) {
      // Find end of headers
      const headerEnd = data.indexOf("\r\n\r\n");
      if (headerEnd < 0) return null;
      const headers = data.substring(0, headerEnd);
      const rest = data.substring(headerEnd + 4);
      
      if (headers.includes("Transfer-Encoding: chunked")) {
        // Parse chunked body
        let body = "";
        let pos = 0;
        while (pos < rest.length) {
          const lineEnd = rest.indexOf("\r\n", pos);
          if (lineEnd < 0) return null; // incomplete
          const chunkSize = parseInt(rest.substring(pos, lineEnd), 16);
          if (isNaN(chunkSize)) return null;
          if (chunkSize === 0) {
            return { headers, body, consumed: headerEnd + 4 + lineEnd + 4 };
          }
          const dataStart = lineEnd + 2;
          if (dataStart + chunkSize + 2 > rest.length) return null; // incomplete
          body += rest.substring(dataStart, dataStart + chunkSize);
          pos = dataStart + chunkSize + 2;
        }
        return null; // incomplete
      }
      return null;
    }
    
    sock.connect(port, "localhost", () => {
      sock.write(req);
      reqCount++;
    });
    
    sock.on("data", (data) => {
      buf += data.toString();
      while (true) {
        const r = parseResponse(buf);
        if (!r) break;
        results.push({ headers: r.headers.substring(0, 200), body: r.body });
        buf = buf.substring(r.consumed);
        if (results.length < 3) {
          setTimeout(() => { sock.write(req); reqCount++; }, 50);
        } else {
          setTimeout(() => sock.destroy(), 100);
        }
      }
    });
    
    sock.on("close", () => resolve({ results, leftover: buf }));
    sock.on("error", reject);
    setTimeout(() => { sock.destroy(); resolve({ results, leftover: buf }); }, 8000);
  });
}


describe("ssi keepalive raw", () => {
  beforeAll(async () => {
    await prepareMockPorts(MOCK_PORTS.POSTGRES);
    pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);
    pgMock.setQueryHandler(/users/i, (q) => {
      if (/SELECT.*count/i.test(q)) return { columns: ["count"], rows: [["3"]] };
      return { columns: ["id","name"], rows: [["1","Alice"],["2","Bob"],["3","Carol"]] };
    });
    pgMock.setQueryHandler(/pg_constraint|pg_class|pg_attribute|pg_namespace|pg_type|information_schema/i, () => ({ columns: ["dummy"], rows: [] }));
    pgMock.setQueryHandler(/^SET\s|^RESET\s/i, () => ({ columns: [], rows: [] }));
    await startNginz("tests/njs/ssi-pgrest.conf", MODULE);
  }, 30000);
  afterAll(async () => {
    await teardownModule(MODULE, [pgMock], [MOCK_PORTS.POSTGRES]);
  });

  test("3 SSI requests on one keepalive TCP connection", async () => {
    const port = 8888;
    const { results, leftover } = await runKeepAlive(port);
    expect(results.length).toBe(3);
    results.forEach(r => expect(r.body).toContain("Alice"));
  });
});
