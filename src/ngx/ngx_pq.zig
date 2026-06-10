const std = @import("std");
const pq = @import("pq.zig");
const ngx = @import("ngx.zig");
const core = @import("ngx_core.zig");
const string = @import("ngx_string.zig");
const expectEqual = std.testing.expectEqual;

const ngx_str_t = string.ngx_str_t;

const PQconninfoOption = pq.PQconninfoOption;

pub const pq_conn_status = enum(pq.ConnStatusType) {
    CONNECTION_OK = pq.CONNECTION_OK,
    CONNECTION_BAD = pq.CONNECTION_BAD,
    CONNECTION_STARTED = pq.CONNECTION_STARTED,
    CONNECTION_MADE = pq.CONNECTION_MADE,
    CONNECTION_AWAITING_RESPONSE = pq.CONNECTION_AWAITING_RESPONSE,
    CONNECTION_AUTH_OK = pq.CONNECTION_AUTH_OK,
    CONNECTION_SETENV = pq.CONNECTION_SETENV,
    CONNECTION_SSL_STARTUP = pq.CONNECTION_SSL_STARTUP,
    CONNECTION_NEEDED = pq.CONNECTION_NEEDED,
    CONNECTION_CHECK_WRITABLE = pq.CONNECTION_CHECK_WRITABLE,
    CONNECTION_CONSUME = pq.CONNECTION_CONSUME,
    CONNECTION_GSS_STARTUP = pq.CONNECTION_GSS_STARTUP,
    CONNECTION_CHECK_TARGET = pq.CONNECTION_CHECK_TARGET,
    CONNECTION_CHECK_STANDBY = pq.CONNECTION_CHECK_STANDBY,
    CONNECTION_ALLOCATED = pq.CONNECTION_ALLOCATED,
    CONNECTION_AUTHENTICATING = pq.CONNECTION_AUTHENTICATING,
};

pub const pq_polling_status = enum(pq.PostgresPollingStatusType) {
    PGRES_POLLING_FAILED = pq.PGRES_POLLING_FAILED,
    PGRES_POLLING_READING = pq.PGRES_POLLING_READING,
    PGRES_POLLING_WRITING = pq.PGRES_POLLING_WRITING,
    PGRES_POLLING_OK = pq.PGRES_POLLING_OK,
    PGRES_POLLING_ACTIVE = pq.PGRES_POLLING_ACTIVE,
};

const PQfinish = pq.PQfinish;
const PQsocket = pq.PQsocket;
const PQstatus = pq.PQstatus;
const PQfreemem = pq.PQfreemem;
const PQconnectPoll = pq.PQconnectPoll;
const PQconndefaults = pq.PQconndefaults;
const PQconninfoFree = pq.PQconninfoFree;
const PQconninfoParse = pq.PQconninfoParse;

// Re-export raw libpq types and functions for module use
pub const PGconn = pq.PGconn;
pub const PGresult = pq.PGresult;
pub const Oid = pq.Oid;
pub const ConnStatusType = pq.ConnStatusType;
pub const ExecStatusType = pq.ExecStatusType;
pub const CONNECTION_OK = pq.CONNECTION_OK;
pub const CONNECTION_BAD = pq.CONNECTION_BAD;
pub const PGRES_COMMAND_OK = pq.PGRES_COMMAND_OK;
pub const PGRES_TUPLES_OK = pq.PGRES_TUPLES_OK;
pub const PGRES_FATAL_ERROR = pq.PGRES_FATAL_ERROR;

pub const pgConnectdb = pq.PQconnectdb;
pub const pgFinish = pq.PQfinish;
pub const pgStatus = pq.PQstatus;
pub const pgExec = pq.PQexec;
pub const pgResultStatus = pq.PQresultStatus;
pub const pgNtuples = pq.PQntuples;
pub const pgNfields = pq.PQnfields;
pub const pgFname = pq.PQfname;
pub const pgFtype = pq.PQftype;
pub const pgGetvalue = pq.PQgetvalue;
pub const pgGetisnull = pq.PQgetisnull;
pub const pgGetlength = pq.PQgetlength;
pub const pgClear = pq.PQclear;
pub const pgErrorMessage = pq.PQerrorMessage;
pub const pgResultErrorMessage = pq.PQresultErrorMessage;
pub const pgResultErrorField = pq.PQresultErrorField;
pub const PG_DIAG_SQLSTATE = pq.PG_DIAG_SQLSTATE;

// Non-blocking connection functions
pub const pgConnectStart = pq.PQconnectStart;
pub const pgConnectPoll = pq.PQconnectPoll;
pub const pgSetnonblocking = pq.PQsetnonblocking;
pub const pgSocket = pq.PQsocket;
pub const pgFlush = pq.PQflush;

// Non-blocking query functions
pub const pgSendQuery = pq.PQsendQuery;
pub const pgSendQueryParams = pq.PQsendQueryParams;
pub const pgConsumeInput = pq.PQconsumeInput;
pub const pgIsBusy = pq.PQisBusy;
pub const pgGetResult = pq.PQgetResult;

// Polling status
pub const PostgresPollingStatusType = pq.PostgresPollingStatusType;
pub const PGRES_POLLING_FAILED = pq.PGRES_POLLING_FAILED;
pub const PGRES_POLLING_READING = pq.PGRES_POLLING_READING;
pub const PGRES_POLLING_WRITING = pq.PGRES_POLLING_WRITING;
pub const PGRES_POLLING_OK = pq.PGRES_POLLING_OK;

pub fn is_valid_pq_conn(con: ngx_str_t, err: [*c]u8) bool {
    if (con.len >= 256) return false;
    var str: [256]u8 = std.mem.zeroes([256]u8);
    core.ngz_memcpy(&str, con.data, con.len);
    const info = PQconninfoParse(&str, @constCast(&err));
    if (info != core.nullptr(PQconninfoOption) and
        err == core.nullptr(u8))
    {
        defer PQconninfoFree(info);
        return true;
    }
    return false;
}

const ngx_log_init = ngx.ngx_log_init;
const ngx_create_pool = ngx.ngx_create_pool;
const ngx_destroy_pool = ngx.ngx_destroy_pool;

test "pq" {
    var long_dsn_buf: [300]u8 = undefined;
    @memset(&long_dsn_buf, 'x');
    const long_dsn = ngx_str_t{ .len = long_dsn_buf.len, .data = &long_dsn_buf };
    try std.testing.expect(!is_valid_pq_conn(long_dsn, core.nullptr(u8)));
}
