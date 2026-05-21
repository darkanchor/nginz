/**
 * Mock PostgreSQL server implementing the wire protocol
 * Supports startup, simple query, and basic authentication
 */

export class PostgresMock {
  constructor(port = 5432) {
    this.port = port;
    this.server = null;
    this.tables = new Map(); // table_name -> [rows]
    this.queryHandlers = new Map(); // query pattern -> handler function
    this.lastSetRole = null; // Track last SET ROLE command
    this.lastSetJwt = null; // Track last SET request.jwt command
    this.queryLog = []; // Log of all queries received
    this.resetRoleCount = 0; // Count of RESET ROLE commands received
    this.connectionError = null; // If set, send this error message during startup instead of AuthenticationOk
  }

  start() {
    this.server = Bun.listen({
      hostname: "127.0.0.1",
      port: this.port,
      socket: {
        data: (socket, data) => this.handleData(socket, data),
        open: (socket) => {
          socket.pgState = "startup";
        },
        close: (socket) => {},
        error: (socket, error) => console.error("PostgreSQL mock error:", error),
      },
    });
    return this;
  }

  stop() {
    if (this.server) {
      this.server.stop();
      this.server = null;
    }
    this.tables.clear();
    this.queryHandlers.clear();
    this.lastSetRole = null;
    this.lastSetJwt = null;
    this.queryLog = [];
  }

  // Clear query tracking (useful between tests)
  clearTracking() {
    this.lastSetRole = null;
    this.lastSetJwt = null;
    this.queryLog = [];
    this.resetRoleCount = 0;
  }

  getResetRoleCount() {
    return this.resetRoleCount;
  }

  // Get the last SET ROLE value
  getLastSetRole() {
    return this.lastSetRole;
  }

  // Get the last SET request.jwt value
  getLastSetJwt() {
    return this.lastSetJwt;
  }

  // Get all queries received so far
  getQueryLog() {
    return [...this.queryLog];
  }

  // Get the last query received
  getLastQuery() {
    return this.queryLog[this.queryLog.length - 1] ?? null;
  }

  handleData(socket, data) {
    const buf = Buffer.from(data);

    if (socket.pgState === "startup") {
      this.handleStartup(socket, buf);
    } else {
      // Process all messages in the buffer (libpq may pipeline multiple)
      let offset = 0;
      while (offset < buf.length) {
        if (offset + 5 > buf.length) break; // incomplete header
        const msgLen = buf.readInt32BE(offset + 1); // length includes itself (4 bytes)
        const totalLen = 1 + msgLen; // type byte + length+body
        if (offset + totalLen > buf.length) break; // incomplete message
        this.handleMessage(socket, buf.slice(offset, offset + totalLen));
        offset += totalLen;
      }
    }
  }

  handleStartup(socket, buf) {
    // Read message length (first 4 bytes)
    const len = buf.readInt32BE(0);
    // Read protocol version (next 4 bytes)
    const version = buf.readInt32BE(4);

    // SSL request (80877103)
    if (version === 80877103) {
      // Reject SSL with 'N'
      socket.write(Buffer.from("N"));
      return;
    }

    // Regular startup message (protocol 3.0 = 196608)
    if (version === 196608) {
      // If connectionError is configured, send an error instead of AuthenticationOk.
      // This lets tests simulate connection-level failures without real DNS.
      if (this.connectionError !== null) {
        this.sendStartupError(socket, this.connectionError);
        socket.end();
        return;
      }

      // Send AuthenticationOk (R\0\0\0\8\0\0\0\0)
      socket.write(Buffer.from([0x52, 0, 0, 0, 8, 0, 0, 0, 0]));

      // Send ParameterStatus messages
      this.sendParameterStatus(socket, "server_version", "15.0");
      this.sendParameterStatus(socket, "client_encoding", "UTF8");
      this.sendParameterStatus(socket, "DateStyle", "ISO, MDY");

      // Send BackendKeyData
      const keyData = Buffer.alloc(13);
      keyData[0] = 0x4b; // 'K'
      keyData.writeInt32BE(12, 1); // length
      keyData.writeInt32BE(1234, 5); // process ID
      keyData.writeInt32BE(5678, 9); // secret key
      socket.write(keyData);

      // Send ReadyForQuery
      socket.write(Buffer.from([0x5a, 0, 0, 0, 5, 0x49])); // 'Z' + length + 'I' (idle)

      socket.pgState = "ready";
    }
  }

  sendParameterStatus(socket, name, value) {
    const len = 4 + name.length + 1 + value.length + 1;
    const buf = Buffer.alloc(1 + len);
    buf[0] = 0x53; // 'S'
    buf.writeInt32BE(len, 1);
    buf.write(name, 5);
    buf[5 + name.length] = 0;
    buf.write(value, 5 + name.length + 1);
    buf[5 + name.length + 1 + value.length] = 0;
    socket.write(buf);
  }

  // Send a PostgreSQL ErrorResponse during startup (before AuthenticationOk).
  // This simulates connection-level failures that libpq reports via pgErrorMessage().
  sendStartupError(socket, message) {
    // PostgreSQL ErrorResponse wire format:
    //   'E' + length (i32, includes self) + field bytes + '\0' terminator
    // Fields: S=Severity, M=Message, C=Code
    const severity = "FATAL\0";
    const code = "08001\0"; // sqlconnection_exception
    const msg = message + "\0";
    const body = "S" + severity + "M" + msg + "C" + code + "\0";
    const len = 4 + body.length; // length includes the 4-byte length field itself
    const buf = Buffer.alloc(1 + len);
    buf[0] = 0x45; // 'E'
    buf.writeInt32BE(len, 1);
    buf.write(body, 5);
    socket.write(buf);
  }

  handleMessage(socket, buf) {
    const msgType = String.fromCharCode(buf[0]);
    const len = buf.readInt32BE(1);

    switch (msgType) {
      case "Q": // Simple Query
        const query = buf.toString("utf8", 5, 5 + len - 5).replace(/\0/g, "");
        this.handleQuery(socket, query);
        break;

      case "X": // Terminate
        socket.end();
        break;

      case "P": { // Parse (extended query) — extract and save query text
        // body: statement_name\0 query\0 [param types]
        const body = buf.slice(5, 5 + len - 4);
        const stmtEnd = body.indexOf(0);
        const queryEnd = body.indexOf(0, stmtEnd + 1);
        socket.extendedQuery = body.toString("utf8", stmtEnd + 1, queryEnd);
        socket.extendedParams = [];
        // Send ParseComplete
        socket.write(Buffer.from([0x31, 0, 0, 0, 4]));
        break;
      }

      case "B": { // Bind — extract parameter values
        // body: portal\0 statement\0 nParamFormats(i16) [formats] nParams(i16) [len(i32)+bytes ...]
        let off = 5;
        while (off < buf.length && buf[off] !== 0) off++; // skip portal name
        off++; // skip null
        while (off < buf.length && buf[off] !== 0) off++; // skip statement name
        off++; // skip null
        const nFormats = buf.readInt16BE(off); off += 2;
        off += nFormats * 2; // skip format codes
        const nParams = buf.readInt16BE(off); off += 2;
        const params = [];
        for (let i = 0; i < nParams; i++) {
          const pLen = buf.readInt32BE(off); off += 4;
          if (pLen === -1) {
            params.push(null);
          } else {
            params.push(buf.toString("utf8", off, off + pLen));
            off += pLen;
          }
        }
        socket.extendedParams = params;
        // Send BindComplete
        socket.write(Buffer.from([0x32, 0, 0, 0, 4]));
        break;
      }

      case "D": // Describe
        // Send NoData
        socket.write(Buffer.from([0x6e, 0, 0, 0, 4]));
        break;

      case "E": { // Execute — run the bound query with substituted parameters
        const rawQuery = socket.extendedQuery || "";
        const params = socket.extendedParams || [];
        // Substitute $N placeholders with the actual parameter values (quoted)
        const resolved = rawQuery.replace(/\$(\d+)/g, (_, n) => {
          const val = params[parseInt(n, 10) - 1];
          if (val === null) return "NULL";
          // Re-quote the value so handleQuery sees it as a quoted literal
          return "'" + val.replace(/'/g, "''") + "'";
        });
        // Pass sendReady=false; Sync sends ReadyForQuery after the full pipeline
        this.handleQuery(socket, resolved, false);
        socket.extendedQuery = null;
        socket.extendedParams = [];
        break;
      }

      case "S": // Sync
        // Send ReadyForQuery
        socket.write(Buffer.from([0x5a, 0, 0, 0, 5, 0x49]));
        break;

      default:
        console.log(`Unknown PostgreSQL message type: ${msgType}`);
    }
  }

  handleQuery(socket, query, sendReady = true) {
    const rfq = () => { if (sendReady) socket.write(Buffer.from([0x5a, 0, 0, 0, 5, 0x49])); };

    // Log all queries for debugging
    this.queryLog.push(query);

    // Check if this is a multi-statement query (semicolon-separated).
    // Real PostgreSQL processes each statement in order, sending a
    // CommandComplete for each non-result-bearing statement before the
    // final ReadyForQuery.
    const statements = query.split(";").map(s => s.trim()).filter(s => s.length > 0);
    if (statements.length > 1) {
      const allSetup = statements.every(s =>
        /^(RESET|SET)\s/i.test(s)
      );
      if (allSetup) {
        // Process each sub-statement: track state, send CommandComplete.
        for (const stmt of statements) {
          this.trackSetupStatement(stmt);
          const tag = /^RESET/i.test(stmt) ? "RESET" : "SET";
          this.sendCommandComplete(socket, tag);
        }
        rfq();
        return;
      }
      // Multi-statement with data queries: process only the first non-SET/RESET
      // statement for now (full multi-statement data support is not needed by
      // current benchmarks).
      for (const stmt of statements) {
        if (/^(RESET|SET)\s/i.test(stmt)) {
          this.trackSetupStatement(stmt);
          const tag = /^RESET/i.test(stmt) ? "RESET" : "SET";
          this.sendCommandComplete(socket, tag);
        } else {
          // Delegate to single-query handler (don't let it send ReadyForQuery
          // because we own that here).
          this.handleSingleQuery(socket, stmt, false);
          rfq();
          return;
        }
      }
      rfq();
      return;
    }

    this.handleSingleQuery(socket, query, sendReady);
  }

  // Track state changes from a single SET or RESET sub-statement (no I/O).
  trackSetupStatement(stmt) {
    if (/^RESET\s+ROLE\s*$/i.test(stmt)) {
      this.resetRoleCount += 1;
      this.lastSetRole = null;
      return;
    }
    const roleMatch = stmt.match(/SET\s+ROLE\s+'([^']+)'/i);
    if (roleMatch) {
      this.lastSetRole = roleMatch[1];
      return;
    }
    const jwtMatch = stmt.match(/SET\s+request\.jwt\s+TO\s+'([^']*)'/i);
    if (jwtMatch) {
      this.lastSetJwt = jwtMatch[1];
      return;
    }
  }

  // Handle a single-statement query (the old handleQuery logic).
  handleSingleQuery(socket, query, sendReady = true) {
    const upperQuery = query.toUpperCase().trim();
    const rfq = () => { if (sendReady) socket.write(Buffer.from([0x5a, 0, 0, 0, 5, 0x49])); };

    // Track RESET ROLE commands (always first in every request's query chain)
    if (/^RESET\s+ROLE\s*$/i.test(query.trim())) {
      this.resetRoleCount += 1;
      // RESET ROLE clears the tracked role to simulate a clean session state
      this.lastSetRole = null;
      this.sendCommandComplete(socket, "RESET");
      rfq();
      return;
    }

    // Track SET ROLE commands
    const roleMatch = query.match(/SET\s+ROLE\s+'([^']+)'/i);
    if (roleMatch) {
      this.lastSetRole = roleMatch[1];
      this.sendCommandComplete(socket, "SET");
      rfq();
      return;
    }

    // Track SET request.jwt commands (including the empty-string clear)
    const jwtMatch = query.match(/SET\s+request\.jwt\s+TO\s+'([^']*)'/i);
    if (jwtMatch) {
      this.lastSetJwt = jwtMatch[1]; // empty string when clearing
      this.sendCommandComplete(socket, "SET");
      rfq();
      return;
    }

    // Check custom handlers first
    for (const [pattern, handler] of this.queryHandlers) {
      if (query.match(pattern)) {
        const result = handler(query);
        if (result?.close) {
          socket.end();
          return;
        }
        if (result?.error) {
          this.sendError(socket, result.error);
          rfq();
          return;
        }
        this.sendQueryResult(socket, result.columns, result.rows);
        rfq();
        return;
      }
    }

    // Built-in query handling
    if (upperQuery.startsWith("SELECT")) {
      this.handleSelect(socket, query);
    } else if (upperQuery.startsWith("INSERT")) {
      this.handleInsert(socket, query);
    } else if (upperQuery.startsWith("UPDATE")) {
      this.handleUpdate(socket, query);
    } else if (upperQuery.startsWith("DELETE")) {
      this.handleDelete(socket, query);
    } else if (upperQuery.startsWith("CREATE")) {
      this.sendCommandComplete(socket, "CREATE TABLE");
    } else if (upperQuery.startsWith("DROP")) {
      this.sendCommandComplete(socket, "DROP TABLE");
    } else if (upperQuery === "BEGIN" || upperQuery === "BEGIN TRANSACTION") {
      this.sendCommandComplete(socket, "BEGIN");
    } else if (upperQuery === "COMMIT") {
      this.sendCommandComplete(socket, "COMMIT");
    } else if (upperQuery === "ROLLBACK") {
      this.sendCommandComplete(socket, "ROLLBACK");
    } else {
      // Unknown query - just return empty result
      this.sendCommandComplete(socket, "OK");
    }

    rfq();
  }

  handleSelect(socket, query) {
    // Parse simple SELECT queries
    const match = query.match(/SELECT\s+(.+)\s+FROM\s+(\w+)/i);
    if (match) {
      const tableName = match[2].toLowerCase();
      const table = this.tables.get(tableName);

      if (table && table.rows.length > 0) {
        this.sendQueryResult(socket, table.columns, table.rows);
        return;
      }
    }

    // Default: return empty result with generic columns
    this.sendQueryResult(socket, ["column1"], []);
  }

  handleInsert(socket, query) {
    this.sendCommandComplete(socket, "INSERT 0 1");
  }

  handleUpdate(socket, query) {
    this.sendCommandComplete(socket, "UPDATE 1");
  }

  handleDelete(socket, query) {
    this.sendCommandComplete(socket, "DELETE 1");
  }

  sendQueryResult(socket, columns, rows) {
    const normalizedColumns = columns.map((col) =>
      typeof col === "string" ? { name: col, typeOid: 25 } : { name: col.name, typeOid: col.typeOid ?? 25 },
    );

    // Send RowDescription
    this.sendRowDescription(socket, normalizedColumns);

    // Send DataRows
    for (const row of rows) {
      this.sendDataRow(socket, row);
    }

    // Send CommandComplete
    this.sendCommandComplete(socket, `SELECT ${rows.length}`);
  }

  sendRowDescription(socket, columns) {
    // Calculate total length
    let len = 4 + 2; // length + field count
    for (const col of columns) {
      len += col.name.length + 1 + 18; // name + null + field info
    }

    const buf = Buffer.alloc(1 + len);
    let offset = 0;

    buf[offset++] = 0x54; // 'T'
    buf.writeInt32BE(len, offset);
    offset += 4;
    buf.writeInt16BE(columns.length, offset);
    offset += 2;

    for (const col of columns) {
      buf.write(col.name, offset);
      offset += col.name.length;
      buf[offset++] = 0; // null terminator

      buf.writeInt32BE(0, offset); // table OID
      offset += 4;
      buf.writeInt16BE(0, offset); // column number
      offset += 2;
      buf.writeInt32BE(col.typeOid ?? 25, offset); // type OID
      offset += 4;
      buf.writeInt16BE(-1, offset); // type size
      offset += 2;
      buf.writeInt32BE(-1, offset); // type modifier
      offset += 4;
      buf.writeInt16BE(0, offset); // format code (text)
      offset += 2;
    }

    socket.write(buf);
  }

  sendDataRow(socket, row) {
    const values = Array.isArray(row) ? row : Object.values(row);
    const strValues = values.map((v) => (v === null ? null : String(v)));

    // Calculate length
    let len = 4 + 2; // length + column count
    for (const v of strValues) {
      len += 4; // value length
      if (v !== null) len += v.length;
    }

    const buf = Buffer.alloc(1 + len);
    let offset = 0;

    buf[offset++] = 0x44; // 'D'
    buf.writeInt32BE(len, offset);
    offset += 4;
    buf.writeInt16BE(strValues.length, offset);
    offset += 2;

    for (const v of strValues) {
      if (v === null) {
        buf.writeInt32BE(-1, offset); // NULL
        offset += 4;
      } else {
        buf.writeInt32BE(v.length, offset);
        offset += 4;
        buf.write(v, offset);
        offset += v.length;
      }
    }

    socket.write(buf);
  }

  sendCommandComplete(socket, tag) {
    const len = 4 + tag.length + 1;
    const buf = Buffer.alloc(1 + len);
    buf[0] = 0x43; // 'C'
    buf.writeInt32BE(len, 1);
    buf.write(tag, 5);
    buf[5 + tag.length] = 0;
    socket.write(buf);
  }

  sendError(socket, error) {
    // Error message format: 'E' + length + severity + code + message + null
    const severity = error?.severity ?? "ERROR";
    const code = error?.code ?? "42000";
    const message = error?.message ?? "mock error";
    const detail = error?.detail ?? null;
    const hint = error?.hint ?? null;

    let len =
      4 +
      1 +
      severity.length +
      1 +
      1 +
      code.length +
      1 +
      1 +
      message.length +
      1;

    if (detail) {
      len += 1 + detail.length + 1;
    }

    if (hint) {
      len += 1 + hint.length + 1;
    }

    len += 1;

    const buf = Buffer.alloc(1 + len);
    let offset = 0;

    buf[offset++] = 0x45; // 'E'
    buf.writeInt32BE(len, offset);
    offset += 4;

    buf[offset++] = 0x53; // 'S' severity
    buf.write(severity, offset);
    offset += severity.length;
    buf[offset++] = 0;

    buf[offset++] = 0x43; // 'C' code
    buf.write(code, offset);
    offset += code.length;
    buf[offset++] = 0;

    buf[offset++] = 0x4d; // 'M' message
    buf.write(message, offset);
    offset += message.length;
    buf[offset++] = 0;

    if (detail) {
      buf[offset++] = 0x44; // 'D' detail
      buf.write(detail, offset);
      offset += detail.length;
      buf[offset++] = 0;
    }

    if (hint) {
      buf[offset++] = 0x48; // 'H' hint
      buf.write(hint, offset);
      offset += hint.length;
      buf[offset++] = 0;
    }

    buf[offset++] = 0; // terminator

    socket.write(buf);
  }

  // Helper methods for test setup
  createTable(name, columns) {
    this.tables.set(name.toLowerCase(), { columns, rows: [] });
  }

  insertRow(tableName, row) {
    const table = this.tables.get(tableName.toLowerCase());
    if (table) {
      table.rows.push(row);
    }
  }

  setQueryHandler(pattern, handler) {
    this.queryHandlers.set(pattern, handler);
  }

  clearTables() {
    this.tables.clear();
  }
}

export function createPostgresMock(port = 5432) {
  return new PostgresMock(port).start();
}
