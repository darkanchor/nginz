import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL, createPostgresMock, MOCK_PORTS } from "../harness.js";
import net from "net";

const MODULE = "njs";
let pgMock;

async function captureAll(port, nRequests, delay = 200) {
  return new Promise((resolve, reject) => {
    const sock = new net.Socket();
    let buf = Buffer.alloc(0);
    let sent = 0;
    const req = Buffer.from("GET /ssi/users HTTP/1.1\r\nHost: localhost\r\nConnection: keep-alive\r\n\r\n");
    
    sock.connect(port, "localhost", () => { sock.write(req); sent++; });
    
    sock.on("data", (data) => {
      buf = Buffer.concat([buf, data]);
      if (sent < nRequests) {
        setTimeout(() => { sock.write(req); sent++; }, delay);
      }
    });
    
    const done = () => resolve(buf);
    sock.on("close", done);
    sock.on("error", reject);
    setTimeout(() => { sock.destroy(); done(); }, 6000);
  });
}

describe("ssi full raw bytes", () => {
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

  test("full raw bytes two SSI requests on one connection", async () => {
    const port = 8888;
    const buf = await captureAll(port, 2, 300);
    const hex = buf.toString("hex");
    const ascii = buf.toString("utf8").replace(/[\r\n]/g, c => c === '\r' ? '\\r' : '\\n');
    console.log(`Total bytes received: ${buf.length}`);
    console.log(`Full content (ascii): ${ascii.substring(0, 1000)}`);
    // Look for HTTP response starts
    let pos = 0;
    let responseCount = 0;
    while (pos < buf.length) {
      const remaining = buf.subarray(pos);
      const httpIdx = remaining.indexOf("HTTP/1.1 ");
      if (httpIdx < 0) break;
      console.log(`Response ${++responseCount} starts at byte ${pos + httpIdx}`);
      pos += httpIdx + 1;
    }
    expect(buf.length).toBeGreaterThan(100);
  });
});
