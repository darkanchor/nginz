const std = @import("std");
const posix = std.posix;
const ngx = @import("ngx");
const libinjection = @import("ngx_libinjection");

const buf = ngx.buf;
const core = ngx.core;
const conf = ngx.conf;
const cjson = ngx.cjson;
const file = ngx.file;
const http = ngx.http;
const regex = ngx.regex;
const shm = ngx.shm;

const NGX_OK = core.NGX_OK;
const NGX_DONE = core.NGX_DONE;
const NGX_AGAIN = core.NGX_AGAIN;
const NGX_ERROR = core.NGX_ERROR;
const NGX_DECLINED = core.NGX_DECLINED;

const ngx_str_t = core.ngx_str_t;
const ngx_int_t = core.ngx_int_t;
const ngx_uint_t = core.ngx_uint_t;
const ngx_flag_t = core.ngx_flag_t;
const ngx_conf_t = conf.ngx_conf_t;
const ngx_buf_t = buf.ngx_buf_t;
const ngx_chain_t = buf.ngx_chain_t;
const ngx_command_t = conf.ngx_command_t;
const ngx_module_t = ngx.module.ngx_module_t;
const ngx_http_module_t = http.ngx_http_module_t;
const ngx_http_request_t = http.ngx_http_request_t;

const ngx_string = ngx.string.ngx_string;
const CJSON = cjson.CJSON;
const ngx_table_elt_t = ngx.hash.ngx_table_elt_t;
const NArray = ngx.array.NArray;
const NList = ngx.list.NList;

const WAF_PHASE_REQUEST: u8 = 1;
const WAF_PHASE_BODY: u8 = 2;

const WAF_TARGET_REQUEST_URI: u8 = 1;
const WAF_TARGET_ARGS: u8 = 2;
const WAF_TARGET_REQUEST_BODY: u8 = 3;
const WAF_TARGET_REQUEST_HEADERS: u8 = 4;
const WAF_TARGET_REQUEST_COOKIES: u8 = 5;
const WAF_TARGET_REQUEST_METHOD: u8 = 6;
const WAF_TARGET_REMOTE_ADDR: u8 = 7;
const WAF_TARGET_QUERY_STRING: u8 = 8;
const WAF_TARGET_REQUEST_LINE: u8 = 9;
const WAF_TARGET_RESPONSE_STATUS: u8 = 10;
const WAF_TARGET_RESPONSE_HEADERS: u8 = 11;
const WAF_TARGET_REQUEST_HEADER_NAMES: u8 = 12;
const WAF_TARGET_REQUEST_PROTOCOL: u8 = 13;
const WAF_TARGET_REQUEST_SCHEME: u8 = 14;
const WAF_TARGET_REQUEST_BASENAME: u8 = 15;
const WAF_TARGET_REQUEST_EXT: u8 = 16;

const WAF_PHASE_RESPONSE: u8 = 3;

const WAF_OPERATOR_CONTAINS: u8 = 1;
const WAF_OPERATOR_LIBINJECTION_SQLI: u8 = 2;
const WAF_OPERATOR_LIBINJECTION_XSS: u8 = 3;
const WAF_OPERATOR_REGEX: u8 = 4;
const WAF_OPERATOR_EQUALS: u8 = 5;
const WAF_OPERATOR_BEGINS_WITH: u8 = 6;
const WAF_OPERATOR_ENDS_WITH: u8 = 7;
const WAF_OPERATOR_PM: u8 = 8;
const WAF_OPERATOR_WITHIN: u8 = 9;
const WAF_OPERATOR_LT: u8 = 10;
const WAF_OPERATOR_LE: u8 = 11;
const WAF_OPERATOR_GT: u8 = 12;
const WAF_OPERATOR_GE: u8 = 13;
const WAF_OPERATOR_IP_MATCH: u8 = 14;
const WAF_OPERATOR_CONTAINS_WORD: u8 = 15;
const WAF_OPERATOR_NO_MATCH: u8 = 16;
const WAF_OPERATOR_UNCONDITIONAL_MATCH: u8 = 17;
const WAF_OPERATOR_VALIDATE_URL_ENCODING: u8 = 18;
const WAF_OPERATOR_VALIDATE_UTF8_ENCODING: u8 = 19;
const WAF_OPERATOR_STRMATCH: u8 = 20;

const WAF_RULE_ACTION_INHERIT: u8 = 0;
const WAF_RULE_ACTION_PASS: u8 = 1;
const WAF_RULE_ACTION_DENY: u8 = 2;

const WAF_TRANSFORM_LOWERCASE: u8 = 1 << 0;
const WAF_TRANSFORM_URL_DECODE: u8 = 1 << 1;
const WAF_TRANSFORM_URL_DECODE_UNI: u8 = 1 << 2;

const WAF_BAN_ZONE_SIZE: usize = 64 * 1024;
const WAF_BAN_MAX_IP_LEN: usize = 64;
const WAF_BAN_MAX_ENTRIES: usize = 256;
const WAF_BAN_MAX_STRIKES: u16 = 10;
const WAF_DEFAULT_SCORE_DECAY_WINDOW: ngx_uint_t = 60;

const waf_rule = extern struct {
    target: u8,
    phase: u8,
    operator: u8,
    id: ngx_uint_t,
    status: ngx_uint_t,
    selector: ngx_str_t,
    pattern: ngx_str_t,
    compiled_regex: ?*regex.ngx_regex_t,
    msg: ngx_str_t,
    tag: ngx_str_t,
    logdata: ngx_str_t,
    action: u8,
    score_weight: u16,
    explicit_score_weight: u8,
    log_match: u8,
    suppress_log: u8,
    transforms: u8,
    explicit_transforms: u8,
};

const waf_ban_entry = extern struct {
    ip_len: u8,
    count: u16,
    strikes: u16,
    score: u16,
    policy_scope: u64,
    first_seen: ngx_uint_t,
    last_seen: ngx_uint_t,
    ban_until: ngx_uint_t,
    ip: [WAF_BAN_MAX_IP_LEN]u8,
};

const waf_ban_store = extern struct {
    initialized: ngx_flag_t,
    entries_count: ngx_uint_t,
    entries: [*c]waf_ban_entry,
};

extern var ngx_http_core_module: ngx_module_t;

// WAF modes
const WAF_MODE_DETECT: ngx_uint_t = 0;
const WAF_MODE_BLOCK: ngx_uint_t = 1;

// WAF location configuration
const waf_loc_conf = extern struct {
    enabled: ngx_flag_t,
    mode: ngx_uint_t, // 0=detect, 1=block
    sqli_enabled: ngx_flag_t,
    xss_enabled: ngx_flag_t,
    check_body: ngx_flag_t,
    rules_file: ngx_str_t,
    rules: [*c]waf_rule,
    rule_count: usize,
    ban_threshold: ngx_uint_t,
    ban_window: ngx_uint_t,
    ban_duration: ngx_uint_t,
    score_threshold: ngx_uint_t,
    score_decay_window: ngx_uint_t,
};

// Request context for tracking WAF state
const WAF_RESULT_ALLOWED: u8 = 0;
const WAF_RESULT_DENIED: u8 = 1;
const WAF_RESULT_DRYRUN: u8 = 2;

const waf_ctx = extern struct {
    done: ngx_flag_t,
    waiting_body: ngx_flag_t,
    finalized: ngx_flag_t,
    lccf: [*c]waf_loc_conf,
    waf_result: u8,
    waf_rule_id: ngx_uint_t,
    waf_category: ngx_str_t,
};

// Detection result
const DetectionResult = struct {
    detected: bool,
    rule_type: []const u8,
    rule_id: ngx_uint_t = 0,
    pattern: []const u8,
    status: ngx_uint_t,
    force_pass: bool = false,
    force_block: bool = false,
    log_match: bool = false,
    suppress_log: bool = false,
    score_weight: u16 = 1,
    tag: []const u8 = "",
    logdata: []const u8 = "",
};

const MatchDisposition = struct {
    block: bool,
    log: bool,
};

const RuleLoadError = struct {
    line_no: usize,
    reason: [:0]const u8,
};

const PM_FROM_FILE_MAX_BYTES: usize = 64 * 1024;

var ngx_http_waf_ban_zone: [*c]core.ngx_shm_zone_t = core.nullptr(core.ngx_shm_zone_t);
var ngx_http_waf_next_header_filter: http.ngx_http_output_header_filter_pt = null;

fn trimAscii(slice: []const u8) []const u8 {
    return std.mem.trim(u8, slice, " \t\r\n");
}

fn lowerDup(pool: [*c]core.ngx_pool_t, value: []const u8) ?ngx_str_t {
    const out_buf = core.castPtr(u8, core.ngx_pnalloc(pool, value.len)) orelse return null;
    for (value, 0..) |c, i| {
        out_buf[i] = toLower(c);
    }
    return ngx_str_t{ .data = out_buf, .len = value.len };
}

fn dupSlice(pool: [*c]core.ngx_pool_t, value: []const u8) ?ngx_str_t {
    const out_buf = core.castPtr(u8, core.ngx_pnalloc(pool, value.len)) orelse return null;
    @memcpy(core.slicify(u8, out_buf, value.len), value);
    return ngx_str_t{ .data = out_buf, .len = value.len };
}

fn appendPmPhrase(out: *std.ArrayList(u8), allocator: std.mem.Allocator, phrase_raw: []const u8) bool {
    const phrase = trimAscii(phrase_raw);
    if (phrase.len == 0 or phrase[0] == '#') return true;

    if (out.items.len > 0) {
        out.append(allocator, ' ') catch return false;
    }

    for (phrase) |c| {
        out.append(allocator, toLower(c)) catch return false;
    }
    return true;
}

fn appendIpMatchEntry(out: *std.ArrayList(u8), allocator: std.mem.Allocator, entry_raw: []const u8) bool {
    const entry = trimAscii(entry_raw);
    if (entry.len == 0 or entry[0] == '#') return true;

    if (out.items.len > 0) {
        out.append(allocator, ' ') catch return false;
    }

    for (entry) |c| {
        out.append(allocator, toLower(c)) catch return false;
    }
    return true;
}

fn loadPmFromFiles(arg_text: []const u8, pool: [*c]core.ngx_pool_t, cf: [*c]ngx_conf_t) ?ngx_str_t {
    const allocator = std.heap.page_allocator;
    var tokens = std.mem.tokenizeAny(u8, arg_text, " \t\r\n");
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(allocator);

    var saw_any_file = false;
    while (tokens.next()) |file_path_raw| {
        if (file_path_raw.len == 0) continue;
        saw_any_file = true;

        var path = dupSlice(pool, file_path_raw) orelse return null;
        if (conf.ngx_conf_full_name(cf.*.cycle, &path, 1) != core.NGX_OK) return null;

        const file_contents_str = file.ngz_open_file(path, cf.*.log, pool) catch return null;
        const file_contents = core.slicify(u8, file_contents_str.data, file_contents_str.len);

        var lines = std.mem.splitScalar(u8, file_contents, '\n');
        while (lines.next()) |line| {
            if (!appendPmPhrase(&combined, allocator, line)) return null;
        }
    }

    if (!saw_any_file or combined.items.len == 0) return null;
    return dupSlice(pool, combined.items);
}

fn loadIpMatchFromFiles(arg_text: []const u8, pool: [*c]core.ngx_pool_t, cf: [*c]ngx_conf_t) ?ngx_str_t {
    const allocator = std.heap.page_allocator;
    var tokens = std.mem.tokenizeAny(u8, arg_text, " \t\r\n");
    var combined = std.ArrayList(u8).empty;
    defer combined.deinit(allocator);

    var saw_any_file = false;
    while (tokens.next()) |file_path_raw| {
        if (file_path_raw.len == 0) continue;
        saw_any_file = true;

        var path = dupSlice(pool, file_path_raw) orelse return null;
        if (conf.ngx_conf_full_name(cf.*.cycle, &path, 1) != core.NGX_OK) return null;

        const file_contents_str = file.ngz_open_file(path, cf.*.log, pool) catch return null;
        const file_contents = core.slicify(u8, file_contents_str.data, file_contents_str.len);

        var lines = std.mem.splitScalar(u8, file_contents, '\n');
        while (lines.next()) |line| {
            if (!appendIpMatchEntry(&combined, allocator, line)) return null;
        }
    }

    if (!saw_any_file or combined.items.len == 0) return null;
    return dupSlice(pool, combined.items);
}

fn parseQuotedSegment(line: []const u8, start_at: usize) ?struct { value: []const u8, next: usize } {
    if (start_at >= line.len or line[start_at] != '"') return null;
    const rest = line[start_at + 1 ..];
    const end_rel = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return .{ .value = rest[0..end_rel], .next = start_at + 1 + end_rel + 1 };
}

fn parseBaseTarget(target: []const u8) ?u8 {
    if (std.mem.eql(u8, target, "REQUEST_URI")) return WAF_TARGET_REQUEST_URI;
    if (std.mem.eql(u8, target, "ARGS")) return WAF_TARGET_ARGS;
    if (std.mem.eql(u8, target, "REQUEST_BODY")) return WAF_TARGET_REQUEST_BODY;
    if (std.mem.eql(u8, target, "REQUEST_HEADERS")) return WAF_TARGET_REQUEST_HEADERS;
    if (std.mem.eql(u8, target, "REQUEST_COOKIES")) return WAF_TARGET_REQUEST_COOKIES;
    if (std.mem.eql(u8, target, "REQUEST_METHOD")) return WAF_TARGET_REQUEST_METHOD;
    if (std.mem.eql(u8, target, "REMOTE_ADDR")) return WAF_TARGET_REMOTE_ADDR;
    if (std.mem.eql(u8, target, "QUERY_STRING")) return WAF_TARGET_QUERY_STRING;
    if (std.mem.eql(u8, target, "REQUEST_LINE")) return WAF_TARGET_REQUEST_LINE;
    if (std.mem.eql(u8, target, "REQUEST_PROTOCOL")) return WAF_TARGET_REQUEST_PROTOCOL;
    if (std.mem.eql(u8, target, "REQUEST_SCHEME")) return WAF_TARGET_REQUEST_SCHEME;
    if (std.mem.eql(u8, target, "REQUEST_BASENAME")) return WAF_TARGET_REQUEST_BASENAME;
    if (std.mem.eql(u8, target, "REQUEST_EXT")) return WAF_TARGET_REQUEST_EXT;
    if (std.mem.eql(u8, target, "RESPONSE_STATUS")) return WAF_TARGET_RESPONSE_STATUS;
    if (std.mem.eql(u8, target, "RESPONSE_HEADERS")) return WAF_TARGET_RESPONSE_HEADERS;
    if (std.mem.eql(u8, target, "REQUEST_HEADER_NAMES")) return WAF_TARGET_REQUEST_HEADER_NAMES;
    return null;
}

fn parseRuleTargetAndSelector(target_text: []const u8, rule: *waf_rule, pool: [*c]core.ngx_pool_t) ?[:0]const u8 {
    if (std.mem.indexOfScalar(u8, target_text, ':')) |sep| {
        const base = trimAscii(target_text[0..sep]);
        const selector = trimAscii(target_text[sep + 1 ..]);
        const target = parseBaseTarget(base) orelse return "unsupported rule target";
        if (selector.len == 0) return "empty rule selector";
        if (target != WAF_TARGET_REQUEST_HEADERS and target != WAF_TARGET_RESPONSE_HEADERS and target != WAF_TARGET_REQUEST_COOKIES and target != WAF_TARGET_ARGS and target != WAF_TARGET_REQUEST_BODY) {
            return "selectors are only supported on ARGS, REQUEST_BODY, REQUEST_HEADERS, RESPONSE_HEADERS, and REQUEST_COOKIES";
        }
        rule.target = target;
        rule.selector = lowerDup(pool, selector) orelse return "unable to allocate selector";
        return null;
    }

    rule.target = parseBaseTarget(target_text) orelse return "unsupported rule target";
    rule.selector = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    return null;
}

fn parseRuleActions(actions: []const u8, rule: *waf_rule, pool: [*c]core.ngx_pool_t) ?[:0]const u8 {
    var it = std.mem.splitScalar(u8, actions, ',');
    var saw_phase = false;
    while (it.next()) |part_raw| {
        const part = trimAscii(part_raw);
        if (part.len == 0) continue;

        if (std.mem.startsWith(u8, part, "id:")) {
            const id_text = trimAscii(part[3..]);
            rule.id = std.fmt.parseInt(ngx_uint_t, id_text, 10) catch return "invalid id action";
        } else if (std.mem.startsWith(u8, part, "status:")) {
            const status_text = trimAscii(part[7..]);
            rule.status = std.fmt.parseInt(ngx_uint_t, status_text, 10) catch return "invalid status action";
        } else if (std.mem.startsWith(u8, part, "phase:")) {
            const phase_text = trimAscii(part[6..]);
            if (std.mem.eql(u8, phase_text, "1")) {
                rule.phase = WAF_PHASE_REQUEST;
            } else if (std.mem.eql(u8, phase_text, "2")) {
                rule.phase = WAF_PHASE_BODY;
            } else if (std.mem.eql(u8, phase_text, "3")) {
                rule.phase = WAF_PHASE_RESPONSE;
            } else {
                return "unsupported phase action";
            }
            saw_phase = true;
        } else if (std.mem.startsWith(u8, part, "msg:")) {
            const msg_text = trimAscii(part[4..]);
            if (msg_text.len >= 2 and ((msg_text[0] == '\'' and msg_text[msg_text.len - 1] == '\'') or (msg_text[0] == '"' and msg_text[msg_text.len - 1] == '"'))) {
                rule.msg = dupSlice(pool, msg_text[1 .. msg_text.len - 1]) orelse return "unable to allocate msg action";
            } else {
                rule.msg = dupSlice(pool, msg_text) orelse return "unable to allocate msg action";
            }
        } else if (std.mem.startsWith(u8, part, "tag:")) {
            const tag_text = trimAscii(part[4..]);
            if (tag_text.len >= 2 and ((tag_text[0] == '\'' and tag_text[tag_text.len - 1] == '\'') or (tag_text[0] == '"' and tag_text[tag_text.len - 1] == '"'))) {
                rule.tag = dupSlice(pool, tag_text[1 .. tag_text.len - 1]) orelse return "unable to allocate tag action";
            } else {
                rule.tag = dupSlice(pool, tag_text) orelse return "unable to allocate tag action";
            }
        } else if (std.mem.startsWith(u8, part, "logdata:")) {
            const logdata_text = trimAscii(part[8..]);
            if (logdata_text.len >= 2 and ((logdata_text[0] == '\'' and logdata_text[logdata_text.len - 1] == '\'') or (logdata_text[0] == '"' and logdata_text[logdata_text.len - 1] == '"'))) {
                rule.logdata = dupSlice(pool, logdata_text[1 .. logdata_text.len - 1]) orelse return "unable to allocate logdata action";
            } else {
                rule.logdata = dupSlice(pool, logdata_text) orelse return "unable to allocate logdata action";
            }
        } else if (std.mem.startsWith(u8, part, "severity:")) {
            const severity_text = trimAscii(part[9..]);
            const severity_value = if (severity_text.len >= 2 and ((severity_text[0] == '\'' and severity_text[severity_text.len - 1] == '\'') or (severity_text[0] == '"' and severity_text[severity_text.len - 1] == '"')))
                severity_text[1 .. severity_text.len - 1]
            else
                severity_text;

            const severity_weight: u16 = if (std.ascii.eqlIgnoreCase(severity_value, "critical"))
                5
            else if (std.ascii.eqlIgnoreCase(severity_value, "error"))
                4
            else if (std.ascii.eqlIgnoreCase(severity_value, "warning"))
                3
            else if (std.ascii.eqlIgnoreCase(severity_value, "notice"))
                2
            else
                return "unsupported severity action";

            if (rule.explicit_score_weight == 0) {
                rule.score_weight = severity_weight;
            }
        } else if (std.mem.eql(u8, part, "deny") or std.mem.eql(u8, part, "block")) {
            if (rule.action != WAF_RULE_ACTION_INHERIT) return "conflicting disruptive actions";
            rule.action = WAF_RULE_ACTION_DENY;
        } else if (std.mem.eql(u8, part, "pass") or std.mem.eql(u8, part, "allow")) {
            if (rule.action != WAF_RULE_ACTION_INHERIT) return "conflicting disruptive actions";
            rule.action = WAF_RULE_ACTION_PASS;
        } else if (std.mem.eql(u8, part, "log")) {
            rule.log_match = 1;
        } else if (std.mem.eql(u8, part, "nolog")) {
            rule.suppress_log = 1;
        } else if (std.mem.startsWith(u8, part, "score:")) {
            const score_text = trimAscii(part[6..]);
            const score_weight = std.fmt.parseInt(u16, score_text, 10) catch return "invalid score action";
            if (score_weight == 0) return "score action must be greater than zero";
            rule.score_weight = score_weight;
            rule.explicit_score_weight = 1;
        } else if (std.mem.startsWith(u8, part, "setvar:")) {
            const expr = trimAscii(part[7..]);
            if (std.mem.startsWith(u8, expr, "ip.score=+")) {
                const score_text = trimAscii(expr[10..]);
                const score_weight = std.fmt.parseInt(u16, score_text, 10) catch return "invalid setvar score increment";
                if (score_weight == 0) return "setvar score increment must be greater than zero";
                rule.score_weight = score_weight;
                rule.explicit_score_weight = 1;
            } else {
                return "unsupported setvar action";
            }
        } else if (std.mem.eql(u8, part, "t:none")) {
            rule.explicit_transforms = 1;
            rule.transforms = 0;
        } else if (std.mem.eql(u8, part, "t:lowercase")) {
            rule.explicit_transforms = 1;
            rule.transforms |= WAF_TRANSFORM_LOWERCASE;
        } else if (std.mem.eql(u8, part, "t:urlDecode")) {
            rule.explicit_transforms = 1;
            rule.transforms |= WAF_TRANSFORM_URL_DECODE;
        } else if (std.mem.eql(u8, part, "t:urlDecodeUni")) {
            rule.explicit_transforms = 1;
            rule.transforms |= WAF_TRANSFORM_URL_DECODE_UNI;
        } else {
            return "unsupported rule action";
        }
    }

    if (!saw_phase) return "missing required phase action";
    return null;
}

fn compileRuleRegex(pattern: ngx_str_t, pool: [*c]core.ngx_pool_t) ?*regex.ngx_regex_t {
    var err_buf: [256]u8 = undefined;
    var rc = regex.initCompile(pattern, pool, &err_buf);
    if (regex.ngx_regex_compile(&rc) != NGX_OK) {
        return null;
    }
    return rc.regex;
}

fn phraseListMatches(normalized: []const u8, pattern_text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, pattern_text, " \t\r\n");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (std.mem.indexOf(u8, normalized, token) != null) return true;
    }
    return false;
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn containsWord(normalized: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;

    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, normalized, search_start, needle)) |idx| {
        const before_ok = idx == 0 or !isWordChar(normalized[idx - 1]);
        const end = idx + needle.len;
        const after_ok = end == normalized.len or !isWordChar(normalized[end]);
        if (before_ok and after_ok) return true;
        search_start = idx + 1;
    }
    return false;
}

fn hasInvalidUrlEncoding(input: []const u8) bool {
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        if (input[i] != '%') continue;
        if (i + 2 >= input.len) return true;
        if (hexCharToValue(input[i + 1]) == null or hexCharToValue(input[i + 2]) == null) return true;
        i += 2;
    }
    return false;
}

fn tokenSetContains(normalized: []const u8, pattern_text: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, pattern_text, " \t\r\n");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (std.mem.eql(u8, normalized, token)) return true;
    }
    return false;
}

fn parseI64Strict(value: []const u8) ?i64 {
    const trimmed = trimAscii(value);
    if (trimmed.len == 0) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

fn numericCompare(normalized: []const u8, pattern_text: []const u8, operator: u8) bool {
    const input_value = parseI64Strict(normalized) orelse return false;
    const pattern_value = parseI64Strict(pattern_text) orelse return false;

    return switch (operator) {
        WAF_OPERATOR_LT => input_value < pattern_value,
        WAF_OPERATOR_LE => input_value <= pattern_value,
        WAF_OPERATOR_GT => input_value > pattern_value,
        WAF_OPERATOR_GE => input_value >= pattern_value,
        else => false,
    };
}

fn cidrContains(input_addr: std.Io.net.IpAddress, cidr: core.ngx_cidr_t) bool {
    return switch (input_addr) {
        .ip4 => |ip4| blk: {
            if (cidr.family != posix.AF.INET) break :blk false;
            const input_bits: u32 = @bitCast(ip4.bytes);
            break :blk (input_bits & cidr.u.in.mask) == cidr.u.in.addr;
        },
        .ip6 => |ip6| blk: {
            if (cidr.family != posix.AF.INET6) break :blk false;
            const cidr_addr = cidr.u.in6.addr.__in6_u.__u6_addr8[0..];
            const cidr_mask = cidr.u.in6.mask.__in6_u.__u6_addr8[0..];
            for (0..16) |i| {
                if ((ip6.bytes[i] & cidr_mask[i]) != cidr_addr[i]) break :blk false;
            }
            break :blk true;
        },
    };
}

fn ipMatchListContains(normalized: []const u8, pattern_text: []const u8) bool {
    const input_addr = std.Io.net.IpAddress.parse(trimAscii(normalized), 0) catch return false;
    var it = std.mem.tokenizeAny(u8, pattern_text, " ,\t\r\n");
    while (it.next()) |token| {
        if (token.len == 0) continue;

        var token_text = ngx_str_t{ .data = @constCast(token.ptr), .len = token.len };
        var cidr = std.mem.zeroes(core.ngx_cidr_t);
        const rc = core.ngx_ptocidr(&token_text, &cidr);
        if (rc != NGX_OK and rc != NGX_DONE) continue;

        if (cidrContains(input_addr, cidr)) return true;
    }
    return false;
}

fn effectiveTransforms(rule: *waf_rule) u8 {
    if (rule.explicit_transforms == 1) return rule.transforms;
    return WAF_TRANSFORM_URL_DECODE | WAF_TRANSFORM_LOWERCASE;
}

fn applyRuleTransforms(rule: *waf_rule, input: []const u8, decode_buf: []u8, lower_buf: []u8) ?[]const u8 {
    const transforms = effectiveTransforms(rule);

    var current = input;
    if ((transforms & (WAF_TRANSFORM_URL_DECODE | WAF_TRANSFORM_URL_DECODE_UNI)) != 0) {
        const decoded_len = urlDecode(input, decode_buf);
        if (decoded_len == 0) return null;
        current = decode_buf[0..@min(decoded_len, decode_buf.len)];
    }

    if ((transforms & WAF_TRANSFORM_LOWERCASE) != 0) {
        const actual_len = @min(current.len, lower_buf.len);
        @memcpy(lower_buf[0..actual_len], current[0..actual_len]);
        toLowerSlice(lower_buf[0..actual_len]);
        return lower_buf[0..actual_len];
    }

    return current;
}

fn parseWafRuleLine(line_raw: []const u8, rule: *waf_rule, pool: [*c]core.ngx_pool_t, cf: [*c]ngx_conf_t) ?[:0]const u8 {
    const line = trimAscii(line_raw);
    if (line.len == 0 or line[0] == '#') return "empty rule line";
    if (!std.mem.startsWith(u8, line, "SecRule ")) return "only SecRule lines are supported";

    const after_prefix = line[8..];
    const first_space = std.mem.indexOfScalar(u8, after_prefix, ' ') orelse return "missing target/operator separator";
    const op_start = 8 + first_space + 1;
    const operator_segment = parseQuotedSegment(line, op_start) orelse return "operator must be double-quoted";
    const actions_start = std.mem.indexOfPos(u8, line, operator_segment.next, "\"") orelse return "missing actions segment";
    const actions_segment = parseQuotedSegment(line, actions_start) orelse return "actions must be double-quoted";

    const operator_text = trimAscii(operator_segment.value);

    rule.* = std.mem.zeroes(waf_rule);
    rule.msg = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    rule.compiled_regex = null;
    rule.status = http.NGX_HTTP_FORBIDDEN;
    rule.score_weight = 1;

    const target_text = trimAscii(after_prefix[0..first_space]);
    if (parseRuleTargetAndSelector(target_text, rule, pool)) |err| return err;

    if (std.mem.startsWith(u8, operator_text, "@contains ")) {
        const pattern_text = trimAscii(operator_text[10..]);
        if (pattern_text.len == 0) return "@contains requires a pattern";
        rule.operator = WAF_OPERATOR_CONTAINS;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate contains pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@strmatch ")) {
        const pattern_text = trimAscii(operator_text[10..]);
        if (pattern_text.len == 0) return "@strmatch requires a pattern";
        rule.operator = WAF_OPERATOR_STRMATCH;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate strmatch pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@beginsWith ")) {
        const pattern_text = trimAscii(operator_text[12..]);
        if (pattern_text.len == 0) return "@beginsWith requires a pattern";
        rule.operator = WAF_OPERATOR_BEGINS_WITH;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate beginsWith pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@endsWith ")) {
        const pattern_text = trimAscii(operator_text[10..]);
        if (pattern_text.len == 0) return "@endsWith requires a pattern";
        rule.operator = WAF_OPERATOR_ENDS_WITH;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate endsWith pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@pm ")) {
        const pattern_text = trimAscii(operator_text[4..]);
        if (pattern_text.len == 0) return "@pm requires at least one phrase";
        rule.operator = WAF_OPERATOR_PM;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate pm phrase list";
    } else if (std.mem.startsWith(u8, operator_text, "@pmFromFile ")) {
        const pattern_text = trimAscii(operator_text[12..]);
        if (pattern_text.len == 0) return "@pmFromFile requires at least one file path";
        rule.operator = WAF_OPERATOR_PM;
        rule.pattern = loadPmFromFiles(pattern_text, pool, cf) orelse return "unable to load pmFromFile phrase list";
    } else if (std.mem.startsWith(u8, operator_text, "@within ")) {
        const pattern_text = trimAscii(operator_text[8..]);
        if (pattern_text.len == 0) return "@within requires at least one candidate value";
        rule.operator = WAF_OPERATOR_WITHIN;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate within candidate list";
    } else if (std.mem.startsWith(u8, operator_text, "@lt ")) {
        const pattern_text = trimAscii(operator_text[4..]);
        if (pattern_text.len == 0) return "@lt requires a numeric value";
        if (parseI64Strict(pattern_text) == null) return "@lt requires a numeric value";
        rule.operator = WAF_OPERATOR_LT;
        rule.pattern = dupSlice(pool, pattern_text) orelse return "unable to allocate lt pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@le ")) {
        const pattern_text = trimAscii(operator_text[4..]);
        if (pattern_text.len == 0) return "@le requires a numeric value";
        if (parseI64Strict(pattern_text) == null) return "@le requires a numeric value";
        rule.operator = WAF_OPERATOR_LE;
        rule.pattern = dupSlice(pool, pattern_text) orelse return "unable to allocate le pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@gt ")) {
        const pattern_text = trimAscii(operator_text[4..]);
        if (pattern_text.len == 0) return "@gt requires a numeric value";
        if (parseI64Strict(pattern_text) == null) return "@gt requires a numeric value";
        rule.operator = WAF_OPERATOR_GT;
        rule.pattern = dupSlice(pool, pattern_text) orelse return "unable to allocate gt pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@ge ")) {
        const pattern_text = trimAscii(operator_text[4..]);
        if (pattern_text.len == 0) return "@ge requires a numeric value";
        if (parseI64Strict(pattern_text) == null) return "@ge requires a numeric value";
        rule.operator = WAF_OPERATOR_GE;
        rule.pattern = dupSlice(pool, pattern_text) orelse return "unable to allocate ge pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@containsWord ")) {
        const pattern_text = trimAscii(operator_text[14..]);
        if (pattern_text.len == 0) return "@containsWord requires a pattern";
        rule.operator = WAF_OPERATOR_CONTAINS_WORD;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate containsWord pattern";
    } else if (std.mem.eql(u8, operator_text, "@noMatch")) {
        rule.operator = WAF_OPERATOR_NO_MATCH;
        rule.pattern = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    } else if (std.mem.eql(u8, operator_text, "@unconditionalMatch")) {
        rule.operator = WAF_OPERATOR_UNCONDITIONAL_MATCH;
        rule.pattern = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    } else if (std.mem.eql(u8, operator_text, "@validateUrlEncoding")) {
        rule.operator = WAF_OPERATOR_VALIDATE_URL_ENCODING;
        rule.pattern = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    } else if (std.mem.eql(u8, operator_text, "@validateUtf8Encoding")) {
        rule.operator = WAF_OPERATOR_VALIDATE_UTF8_ENCODING;
        rule.pattern = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    } else if (std.mem.startsWith(u8, operator_text, "@ipMatchFromFile ")) {
        const pattern_text = trimAscii(operator_text[17..]);
        if (pattern_text.len == 0) return "@ipMatchFromFile requires at least one file path";
        rule.operator = WAF_OPERATOR_IP_MATCH;
        rule.pattern = loadIpMatchFromFiles(pattern_text, pool, cf) orelse return "unable to load ipMatchFromFile entries";
    } else if (std.mem.startsWith(u8, operator_text, "@ipMatch ")) {
        const pattern_text = trimAscii(operator_text[9..]);
        if (pattern_text.len == 0) return "@ipMatch requires at least one IP or CIDR";
        rule.operator = WAF_OPERATOR_IP_MATCH;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate ipMatch pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@streq ") or std.mem.startsWith(u8, operator_text, "@eq ")) {
        const offset: usize = if (std.mem.startsWith(u8, operator_text, "@streq ")) 7 else 4;
        const pattern_text = trimAscii(operator_text[offset..]);
        if (pattern_text.len == 0) return "equals operator requires a value";
        rule.operator = WAF_OPERATOR_EQUALS;
        rule.pattern = lowerDup(pool, pattern_text) orelse return "unable to allocate equals pattern";
    } else if (std.mem.startsWith(u8, operator_text, "@rx ")) {
        const pattern_text = trimAscii(operator_text[4..]);
        if (pattern_text.len == 0) return "@rx requires a pattern";
        rule.operator = WAF_OPERATOR_REGEX;
        rule.pattern = dupSlice(pool, pattern_text) orelse return "unable to allocate regex pattern";
        rule.compiled_regex = compileRuleRegex(rule.pattern, pool) orelse return "invalid regex pattern";
    } else if (std.mem.eql(u8, operator_text, "@libinjection_sqli")) {
        rule.operator = WAF_OPERATOR_LIBINJECTION_SQLI;
        rule.pattern = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    } else if (std.mem.eql(u8, operator_text, "@libinjection_xss")) {
        rule.operator = WAF_OPERATOR_LIBINJECTION_XSS;
        rule.pattern = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
    } else {
        return "unsupported rule operator";
    }

    if (parseRuleActions(actions_segment.value, rule, pool)) |err| return err;
    if (rule.target == WAF_TARGET_REQUEST_BODY and rule.phase != WAF_PHASE_BODY) return "REQUEST_BODY rules must use phase:2";
    if ((rule.target == WAF_TARGET_RESPONSE_STATUS or rule.target == WAF_TARGET_RESPONSE_HEADERS) and rule.phase != WAF_PHASE_RESPONSE) {
        return "response rules must use phase:3";
    }
    if (rule.target != WAF_TARGET_REQUEST_BODY and rule.target != WAF_TARGET_RESPONSE_STATUS and rule.target != WAF_TARGET_RESPONSE_HEADERS and rule.phase != WAF_PHASE_REQUEST) {
        return "request rules must use phase:1";
    }

    return null;
}

fn loadWafRules(contents: ngx_str_t, pool: [*c]core.ngx_pool_t, cf: [*c]ngx_conf_t, out_rules: *[*c]waf_rule, out_count: *usize, out_error: *?RuleLoadError) bool {
    const text = core.slicify(u8, contents.data, contents.len);

    var count: usize = 0;
    var line_no: usize = 0;
    var count_it = std.mem.splitScalar(u8, text, '\n');
    while (count_it.next()) |line| {
        line_no += 1;
        const trimmed = trimAscii(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (!std.mem.startsWith(u8, trimmed, "SecRule ")) {
            out_error.* = RuleLoadError{ .line_no = line_no, .reason = "only SecRule lines are supported" };
            return false;
        }
        count += 1;
    }

    if (count == 0) {
        out_rules.* = core.nullptr(waf_rule);
        out_count.* = 0;
        return true;
    }

    const rules_mem = core.castPtr(waf_rule, core.ngx_pcalloc(pool, count * @sizeOf(waf_rule))) orelse return false;
    var index: usize = 0;
    line_no = 0;
    var parse_it = std.mem.splitScalar(u8, text, '\n');
    while (parse_it.next()) |line| {
        line_no += 1;
        const trimmed = trimAscii(line);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const rule_ptr: *waf_rule = @ptrCast(&rules_mem[index]);
        if (parseWafRuleLine(trimmed, rule_ptr, pool, cf)) |err| {
            out_error.* = RuleLoadError{ .line_no = line_no, .reason = err };
            return false;
        }
        index += 1;
    }

    out_rules.* = rules_mem;
    out_count.* = count;
    return true;
}

fn analyzeCustomRules(input: []const u8, target: u8, phase: u8, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    if (lccf.rule_count == 0 or lccf.rules == null) {
        return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
    }

    for (0..lccf.rule_count) |i| {
        const rule: *waf_rule = @ptrCast(&lccf.rules[i]);
        if (rule.selector.len != 0) continue;
        if (rule.target != target or rule.phase != phase) continue;

        const normalized = applyRuleTransforms(rule, input, decode_buf, lower_buf) orelse continue;
        var decoded_str = ngx_str_t{ .data = @constCast(normalized.ptr), .len = normalized.len };

        switch (rule.operator) {
            WAF_OPERATOR_CONTAINS => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (std.mem.indexOf(u8, normalized, pattern) != null) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_STRMATCH => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (std.mem.indexOf(u8, normalized, pattern) != null) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_BEGINS_WITH => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (std.mem.startsWith(u8, normalized, pattern)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_ENDS_WITH => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (std.mem.endsWith(u8, normalized, pattern)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_PM => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (phraseListMatches(normalized, pattern)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_WITHIN => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (tokenSetContains(normalized, pattern)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_LT, WAF_OPERATOR_LE, WAF_OPERATOR_GT, WAF_OPERATOR_GE => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (numericCompare(normalized, pattern, rule.operator)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_CONTAINS_WORD => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (containsWord(normalized, pattern)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_NO_MATCH => {},
            WAF_OPERATOR_UNCONDITIONAL_MATCH => {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "unconditionalMatch";
                return buildRuleDetection(rule, detail);
            },
            WAF_OPERATOR_VALIDATE_URL_ENCODING => {
                if (hasInvalidUrlEncoding(input)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "validateUrlEncoding";
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_VALIDATE_UTF8_ENCODING => {
                if (!std.unicode.utf8ValidateSlice(input)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "validateUtf8Encoding";
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_IP_MATCH => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (ipMatchListContains(normalized, pattern)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_LIBINJECTION_SQLI => {
                if (libinjection.detectSqli(normalized)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "libinjection_sqli";
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_LIBINJECTION_XSS => {
                if (libinjection.detectXss(normalized)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "libinjection_xss";
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_EQUALS => {
                const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
                if (std.mem.eql(u8, normalized, pattern)) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                    return buildRuleDetection(rule, detail);
                }
            },
            WAF_OPERATOR_REGEX => {
                if (rule.compiled_regex != null) {
                    const rc = regex.ngx_regex_exec(rule.compiled_regex, &decoded_str, core.nullptr(c_int), 0);
                    if (rc >= 0) {
                        const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else core.slicify(u8, rule.pattern.data, rule.pattern.len);
                        return buildRuleDetection(rule, detail);
                    }
                }
            },
            else => {},
        }
    }

    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn hasBodyRules(lccf: *waf_loc_conf) bool {
    for (0..lccf.rule_count) |i| {
        if (lccf.rules[i].target == WAF_TARGET_REQUEST_BODY) return true;
    }
    return false;
}

fn hasBodySelectorRules(lccf: *waf_loc_conf) bool {
    for (0..lccf.rule_count) |i| {
        const rule = &lccf.rules[i];
        if (rule.target == WAF_TARGET_REQUEST_BODY and rule.selector.len != 0) return true;
    }
    return false;
}

fn buildRuleDetection(rule: *waf_rule, detail: []const u8) DetectionResult {
    return DetectionResult{
        .detected = true,
        .rule_type = "rule",
        .rule_id = rule.id,
        .pattern = detail,
        .status = rule.status,
        .force_pass = rule.action == WAF_RULE_ACTION_PASS,
        .force_block = rule.action == WAF_RULE_ACTION_DENY,
        .log_match = rule.log_match == 1,
        .suppress_log = rule.suppress_log == 1,
        .score_weight = if (rule.score_weight == 0) 1 else rule.score_weight,
        .tag = if (rule.tag.len > 0 and rule.tag.data != null) core.slicify(u8, rule.tag.data, rule.tag.len) else "",
        .logdata = if (rule.logdata.len > 0 and rule.logdata.data != null) core.slicify(u8, rule.logdata.data, rule.logdata.len) else "",
    };
}

fn resolveMatchDisposition(result: DetectionResult, lccf: *waf_loc_conf) MatchDisposition {
    const should_block = if (result.force_pass)
        false
    else if (result.force_block)
        true
    else
        lccf.*.mode == WAF_MODE_BLOCK;

    return MatchDisposition{
        .block = should_block,
        .log = if (result.suppress_log) false else result.log_match or !should_block,
    };
}

fn getRequestContentType(r: [*c]ngx_http_request_t) ?[]const u8 {
    if (r.*.headers_in.content_type == null) return null;
    const content_type = r.*.headers_in.content_type.*.value;
    if (content_type.len == 0 or content_type.data == null) return null;
    return core.slicify(u8, content_type.data, content_type.len);
}

fn analyzeBodyFormSelectorRules(body: []const u8, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    var fields = std.mem.splitScalar(u8, body, '&');
    while (fields.next()) |field_raw| {
        const field = trimAscii(field_raw);
        if (field.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, field, '=') orelse continue;
        const name = trimAscii(field[0..eq]);
        const value = trimAscii(field[eq + 1 ..]);

        var name_buf: [256]u8 = undefined;
        const name_len = @min(name.len, name_buf.len);
        @memcpy(name_buf[0..name_len], name[0..name_len]);
        toLowerSlice(name_buf[0..name_len]);

        for (0..lccf.rule_count) |i| {
            const rule: *waf_rule = @ptrCast(&lccf.rules[i]);
            if (rule.target != WAF_TARGET_REQUEST_BODY or rule.phase != WAF_PHASE_BODY or rule.selector.len == 0) continue;
            const selector = core.slicify(u8, rule.selector.data, rule.selector.len);
            if (!std.mem.eql(u8, name_buf[0..name_len], selector)) continue;

            const single = analyzeSingleRule(rule, value, decode_buf, lower_buf);
            if (single.detected) return single;
        }
    }

    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn analyzeBodyJsonSelectorRules(body: []const u8, pool: [*c]core.ngx_pool_t, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    var cj = CJSON.init(pool);
    const parsed = cj.decode(ngx_str_t{ .data = @constCast(body.ptr), .len = body.len }) catch {
        return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
    };
    defer cj.free(parsed);

    for (0..lccf.rule_count) |i| {
        const rule: *waf_rule = @ptrCast(&lccf.rules[i]);
        if (rule.target != WAF_TARGET_REQUEST_BODY or rule.phase != WAF_PHASE_BODY or rule.selector.len == 0) continue;
        const selector = core.slicify(u8, rule.selector.data, rule.selector.len);

        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "$.{s}", .{selector}) catch continue;
        const node = CJSON.query(parsed, path) orelse continue;

        if (CJSON.stringValue(node)) |string_value| {
            const single = analyzeSingleRule(rule, core.slicify(u8, string_value.data, string_value.len), decode_buf, lower_buf);
            if (single.detected) return single;
            continue;
        }

        if (CJSON.boolValue(node)) |bool_value| {
            const bool_text = if (bool_value) "true" else "false";
            const single = analyzeSingleRule(rule, bool_text, decode_buf, lower_buf);
            if (single.detected) return single;
            continue;
        }

        const encoded = cj.encode(node) catch continue;
        const single = analyzeSingleRule(rule, core.slicify(u8, encoded.data, encoded.len), decode_buf, lower_buf);
        if (single.detected) return single;
    }

    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn extractMultipartBoundary(content_type: []const u8) ?[]const u8 {
    const marker = "boundary=";
    const start = std.mem.indexOf(u8, content_type, marker) orelse return null;
    var boundary = trimAscii(content_type[start + marker.len ..]);
    if (boundary.len == 0) return null;
    if (std.mem.indexOfScalar(u8, boundary, ';')) |semi| {
        boundary = trimAscii(boundary[0..semi]);
    }
    if (boundary.len >= 2 and boundary[0] == '"' and boundary[boundary.len - 1] == '"') {
        boundary = boundary[1 .. boundary.len - 1];
    }
    if (boundary.len == 0) return null;
    return boundary;
}

fn extractMultipartName(headers: []const u8) ?[]const u8 {
    const marker = "name=\"";
    const start = std.mem.indexOf(u8, headers, marker) orelse return null;
    const rest = headers[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..end];
}

fn trimMultipartValue(value: []const u8) []const u8 {
    var trimmed = value;
    while (trimmed.len >= 2 and std.mem.endsWith(u8, trimmed, "\r\n")) {
        trimmed = trimmed[0 .. trimmed.len - 2];
    }
    return trimmed;
}

fn analyzeBodyMultipartSelectorRules(body: []const u8, content_type: []const u8, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    const boundary = extractMultipartBoundary(content_type) orelse {
        return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
    };

    var delimiter_buf: [256]u8 = undefined;
    const delimiter = std.fmt.bufPrint(&delimiter_buf, "--{s}", .{boundary}) catch {
        return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
    };

    var parts = std.mem.splitSequence(u8, body, delimiter);
    while (parts.next()) |part_raw| {
        var part = trimAscii(part_raw);
        if (part.len == 0 or std.mem.eql(u8, part, "--")) continue;
        if (std.mem.startsWith(u8, part, "--")) continue;
        if (std.mem.startsWith(u8, part, "\r\n")) part = part[2..];

        const header_end = std.mem.indexOf(u8, part, "\r\n\r\n") orelse continue;
        const headers = part[0..header_end];
        const value = trimMultipartValue(part[header_end + 4 ..]);
        const name = extractMultipartName(headers) orelse continue;

        var name_buf: [256]u8 = undefined;
        const name_len = @min(name.len, name_buf.len);
        @memcpy(name_buf[0..name_len], name[0..name_len]);
        toLowerSlice(name_buf[0..name_len]);

        for (0..lccf.rule_count) |i| {
            const rule: *waf_rule = @ptrCast(&lccf.rules[i]);
            if (rule.target != WAF_TARGET_REQUEST_BODY or rule.phase != WAF_PHASE_BODY or rule.selector.len == 0) continue;
            const selector = core.slicify(u8, rule.selector.data, rule.selector.len);
            if (!std.mem.eql(u8, name_buf[0..name_len], selector)) continue;

            const single = analyzeSingleRule(rule, value, decode_buf, lower_buf);
            if (single.detected) return single;
        }
    }

    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn analyzeBodySelectorRules(r: [*c]ngx_http_request_t, body: []const u8, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    if (!hasBodySelectorRules(lccf)) {
        return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
    }

    const content_type = getRequestContentType(r) orelse {
        return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
    };

    if (std.mem.indexOf(u8, content_type, "application/x-www-form-urlencoded") != null) {
        return analyzeBodyFormSelectorRules(body, lccf, decode_buf, lower_buf);
    }

    if (std.mem.indexOf(u8, content_type, "application/json") != null) {
        return analyzeBodyJsonSelectorRules(body, r.*.pool, lccf, decode_buf, lower_buf);
    }

    if (std.mem.indexOf(u8, content_type, "multipart/form-data") != null) {
        return analyzeBodyMultipartSelectorRules(body, content_type, lccf, decode_buf, lower_buf);
    }

    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn nowSeconds() ngx_uint_t {
    return @intCast(core.ngx_time());
}

fn getBanStore() ?[*c]waf_ban_store {
    if (ngx_http_waf_ban_zone == core.nullptr(core.ngx_shm_zone_t)) return null;
    if (ngx_http_waf_ban_zone.*.data != null) {
        return core.castPtr(waf_ban_store, ngx_http_waf_ban_zone.*.data);
    }

    if (ngx_http_waf_ban_zone.*.shm.addr != null) {
        const shpool = core.castPtr(core.ngx_slab_pool_t, ngx_http_waf_ban_zone.*.shm.addr) orelse return null;
        if (shpool.*.data != null) {
            return core.castPtr(waf_ban_store, shpool.*.data);
        }
    }

    return null;
}

fn getBanStoreFromZone(zone: [*c]core.ngx_shm_zone_t) ?[*c]waf_ban_store {
    if (zone == core.nullptr(core.ngx_shm_zone_t) or zone.*.shm.addr == null) return null;

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return null;
    if (shpool.*.data != null) {
        const store = core.castPtr(waf_ban_store, shpool.*.data) orelse return null;
        zone.*.data = store;
        return store;
    }

    if (zone.*.data != null) {
        return core.castPtr(waf_ban_store, zone.*.data);
    }

    return null;
}

fn ensureBanStore(zone: [*c]core.ngx_shm_zone_t, shpool: [*c]core.ngx_slab_pool_t) ?[*c]waf_ban_store {
    if (zone == core.nullptr(core.ngx_shm_zone_t) or shpool == null) return null;

    if (zone.*.data != null) {
        return core.castPtr(waf_ban_store, zone.*.data);
    }

    if (shpool.*.data != null) {
        const store = core.castPtr(waf_ban_store, shpool.*.data) orelse return null;
        zone.*.data = store;
        return store;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(waf_ban_store)) orelse return null;
    const store = core.castPtr(waf_ban_store, store_mem) orelse return null;
    const entries_mem = shm.ngx_slab_calloc(shpool, @sizeOf(waf_ban_entry) * WAF_BAN_MAX_ENTRIES) orelse return null;
    const entries = core.castPtr(waf_ban_entry, entries_mem) orelse return null;

    store.*.initialized = 1;
    store.*.entries_count = 0;
    store.*.entries = entries;
    shpool.*.data = store;
    zone.*.data = store;
    return store;
}

fn getClientIp(r: [*c]ngx_http_request_t) ?[]const u8 {
    if (r.*.connection != null and r.*.connection.*.addr_text.len > 0 and r.*.connection.*.addr_text.data != null) {
        const raw = core.slicify(u8, r.*.connection.*.addr_text.data, r.*.connection.*.addr_text.len);
        const len = std.mem.indexOfScalar(u8, raw, 0) orelse raw.len;
        return raw[0..len];
    }
    return null;
}

fn decayBanEntry(entry: *waf_ban_entry, now: ngx_uint_t, lccf: *waf_loc_conf) void {
    if (entry.ban_until != 0 and entry.ban_until <= now) {
        entry.ban_until = 0;
        entry.count = 0;
        entry.first_seen = 0;
    }

    if (entry.last_seen != 0 and now > entry.last_seen) {
        const quiet_period = now - entry.last_seen;
        if (quiet_period > lccf.ban_window * 4) {
            entry.strikes = 0;
        } else if (quiet_period > lccf.ban_window * 2 and entry.strikes > 0) {
            entry.strikes -= 1;
        }

        if (lccf.score_decay_window > 0) {
            const score_decay_steps = quiet_period / lccf.score_decay_window;
            if (score_decay_steps >= entry.score) {
                entry.score = 0;
            } else {
                entry.score -= @intCast(score_decay_steps);
            }
        }
    }
}

fn resetBanEntry(entry: *waf_ban_entry) void {
    entry.* = std.mem.zeroes(waf_ban_entry);
}

fn snapshotBanEntry(entry: *waf_ban_entry) void {
    var snapshot_buf: [128]u8 = undefined;
    const snapshot = std.fmt.bufPrint(&snapshot_buf, "{}:{}:{}:{}:{}:{}", .{ entry.*.count, entry.*.strikes, entry.*.score, entry.*.ban_until, entry.*.first_seen, entry.*.last_seen }) catch return;
    std.mem.doNotOptimizeAway(snapshot);
}

fn hashPolicyBytes(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* *%= 1099511628211;
    }
}

fn policyScope(lccf: *waf_loc_conf) u64 {
    var hash: u64 = 14695981039346656037;
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.enabled));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.mode));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.sqli_enabled));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.xss_enabled));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.check_body));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.ban_threshold));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.ban_window));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.ban_duration));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.score_threshold));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.score_decay_window));
    hashPolicyBytes(&hash, std.mem.asBytes(&lccf.rule_count));
    if (lccf.rules_file.data != null) hashPolicyBytes(&hash, core.slicify(u8, lccf.rules_file.data, lccf.rules_file.len));
    return hash;
}

fn assignBanEntry(entry: *waf_ban_entry, ip: []const u8, scope: u64) void {
    resetBanEntry(entry);
    const copy_len: usize = @min(ip.len, WAF_BAN_MAX_IP_LEN);
    @memcpy(entry.ip[0..copy_len], ip[0..copy_len]);
    entry.ip_len = @intCast(copy_len);
    entry.policy_scope = scope;
}

fn computeBanDuration(lccf: *waf_loc_conf, strikes: u16) ngx_uint_t {
    const multiplier: ngx_uint_t = @intCast(@max(@as(u16, 1), strikes));
    return lccf.ban_duration * multiplier;
}

fn applyOffenseToEntry(entry: *waf_ban_entry, now: ngx_uint_t, lccf: *waf_loc_conf, score_weight: u16) void {
    if (entry.*.ban_until > now) return;

    if (lccf.score_threshold > 0 and entry.score < std.math.maxInt(u16)) {
        entry.score +|= score_weight;
    }

    if (lccf.score_threshold > 0 and entry.score >= lccf.score_threshold) {
        if (entry.*.strikes < WAF_BAN_MAX_STRIKES) {
            entry.*.strikes += 1;
        }
        entry.*.ban_until = now + computeBanDuration(lccf, entry.*.strikes);
        entry.*.count = 0;
        entry.*.first_seen = now;
        entry.*.last_seen = now;
        entry.*.score = 0;
        return;
    }

    if (lccf.ban_threshold == 0) {
        entry.*.last_seen = now;
        return;
    }

    if (entry.*.first_seen == 0 or now - entry.*.first_seen > lccf.ban_window) {
        entry.*.first_seen = now;
        entry.*.count = 1;
        entry.*.last_seen = now;
        return;
    }

    entry.*.count += 1;
    entry.*.last_seen = now;
    if (entry.*.count >= lccf.ban_threshold) {
        if (entry.*.strikes < WAF_BAN_MAX_STRIKES) {
            entry.*.strikes += 1;
        }
        entry.*.ban_until = now + computeBanDuration(lccf, entry.*.strikes);
        entry.*.count = 0;
        entry.*.first_seen = now;
        entry.*.last_seen = now;
        entry.*.score = 0;
    }
}

fn findBanEntry(store: [*c]waf_ban_store, ip: []const u8, scope: u64) ?[*c]waf_ban_entry {
    for (0..store.*.entries_count) |i| {
        const entry: [*c]waf_ban_entry = store.*.entries + i;
        const entry_ip: []const u8 = @ptrCast(entry[0].ip[0..entry[0].ip_len]);
        if (entry[0].policy_scope == scope and entry[0].ip_len == ip.len and std.mem.eql(u8, entry_ip, ip)) {
            return entry;
        }
    }
    return null;
}

fn getOrCreateBanEntry(shpool: [*c]core.ngx_slab_pool_t, store: [*c]waf_ban_store, ip: []const u8, lccf: *waf_loc_conf) ?[*c]waf_ban_entry {
    const now = nowSeconds();
    const scope = policyScope(lccf);
    if (findBanEntry(store, ip, scope)) |entry| {
        decayBanEntry(entry, now, lccf);
        return entry;
    }

    if (store.*.entries_count < WAF_BAN_MAX_ENTRIES) {
        const entry: [*c]waf_ban_entry = store.*.entries + store.*.entries_count;
        const entry_ref: *waf_ban_entry = @ptrCast(@alignCast(entry));
        store.*.entries_count += 1;
        assignBanEntry(entry_ref, ip, scope);
        return entry;
    }

    var candidate: ?[*c]waf_ban_entry = null;
    for (0..store.*.entries_count) |i| {
        const entry: [*c]waf_ban_entry = store.*.entries + i;
        const entry_ref: *waf_ban_entry = @ptrCast(@alignCast(entry));
        decayBanEntry(entry_ref, now, lccf);
        if (entry[0].ban_until == 0 and entry[0].count == 0 and entry[0].strikes == 0) {
            assignBanEntry(entry_ref, ip, scope);
            return entry;
        }

        if (candidate == null or entry[0].last_seen < candidate.?[0].last_seen) {
            candidate = entry;
        }
    }

    _ = shpool;
    if (candidate) |entry| {
        assignBanEntry(entry, ip, scope);
        return entry;
    }

    return null;
}

fn isClientBanned(r: [*c]ngx_http_request_t, lccf: *waf_loc_conf) bool {
    if (lccf.ban_threshold == 0 and lccf.score_threshold == 0) return false;
    const ip = getClientIp(r) orelse return false;
    const zone = ngx_http_waf_ban_zone;
    const shpool = if (zone != core.nullptr(core.ngx_shm_zone_t) and zone.*.shm.addr != null and zone.*.data != null)
        core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr)
    else if (zone != core.nullptr(core.ngx_shm_zone_t) and zone.*.shm.addr != null)
        core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr)
    else
        null;
    if (shpool == null) return false;

    shm.ngx_shmtx_lock(&shpool.?.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.?.*.mutex);

    const store = if (getBanStoreFromZone(zone)) |existing| existing else ensureBanStore(zone, shpool.?) orelse return false;

    if (findBanEntry(store, ip, policyScope(lccf))) |entry| {
        const now = nowSeconds();
        decayBanEntry(entry, now, lccf);
        snapshotBanEntry(entry);
        if (entry.*.ban_until > now) return true;
    }
    return false;
}

fn recordOffense(r: [*c]ngx_http_request_t, lccf: *waf_loc_conf, score_weight: u16) void {
    if (lccf.ban_threshold == 0 and lccf.score_threshold == 0) return;
    const ip = getClientIp(r) orelse return;
    const zone = ngx_http_waf_ban_zone;
    const shpool = if (zone != core.nullptr(core.ngx_shm_zone_t) and zone.*.shm.addr != null and zone.*.data != null)
        core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr)
    else if (zone != core.nullptr(core.ngx_shm_zone_t) and zone.*.shm.addr != null)
        core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr)
    else
        null;

    if (shpool == null) return;
    shm.ngx_shmtx_lock(&shpool.?.*.mutex);
    defer shm.ngx_shmtx_unlock(&shpool.?.*.mutex);

    const store = if (getBanStoreFromZone(zone)) |existing| existing else ensureBanStore(zone, shpool.?) orelse return;
    const entry = getOrCreateBanEntry(shpool.?, store, ip, lccf) orelse return;
    const now = nowSeconds();
    applyOffenseToEntry(entry, now, lccf, @max(@as(u16, 1), score_weight));
    snapshotBanEntry(entry);
}

fn ngx_http_waf_ban_zone_init(zone: [*c]core.ngx_shm_zone_t, data: ?*anyopaque) callconv(.c) ngx_int_t {
    if (data != null) {
        zone.*.data = data;
        return NGX_OK;
    }

    const shpool = core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr) orelse return NGX_ERROR;
    if (shpool.*.data != null) {
        zone.*.data = shpool.*.data;
        return NGX_OK;
    }

    const store_mem = shm.ngx_slab_calloc(shpool, @sizeOf(waf_ban_store)) orelse return NGX_ERROR;
    const store = core.castPtr(waf_ban_store, store_mem) orelse return NGX_ERROR;
    const entries_mem = shm.ngx_slab_calloc(shpool, @sizeOf(waf_ban_entry) * WAF_BAN_MAX_ENTRIES) orelse return NGX_ERROR;
    const entries = core.castPtr(waf_ban_entry, entries_mem) orelse return NGX_ERROR;

    store.*.initialized = 1;
    store.*.entries_count = 0;
    store.*.entries = entries;
    shpool.*.data = store;
    zone.*.data = store;
    return NGX_OK;
}

fn collectRequestHeaders(r: [*c]ngx_http_request_t, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_in.headers);
    var it = headers.iterator();

    var total_len: usize = 0;
    while (it.next()) |h| {
        total_len += h.*.key.len + 2 + h.*.value.len + 1;
    }
    if (total_len == 0) return null;

    const out = core.castPtr(u8, core.ngx_pnalloc(pool, total_len)) orelse return null;
    var pos: usize = 0;

    var headers2 = NList(ngx_table_elt_t).init0(&r.*.headers_in.headers);
    var it2 = headers2.iterator();
    while (it2.next()) |h| {
        const key = core.slicify(u8, h.*.key.data, h.*.key.len);
        const value = core.slicify(u8, h.*.value.data, h.*.value.len);
        @memcpy(out[pos..][0..key.len], key);
        pos += key.len;
        out[pos] = ':';
        out[pos + 1] = ' ';
        pos += 2;
        @memcpy(out[pos..][0..value.len], value);
        pos += value.len;
        out[pos] = '\n';
        pos += 1;
    }

    return ngx_str_t{ .data = out, .len = pos };
}

fn collectResponseHeaders(r: [*c]ngx_http_request_t, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    var total_len: usize = 0;
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
    var it = headers.iterator();
    while (it.next()) |h| {
        total_len += h.*.key.len + h.*.value.len + 3;
    }
    if (total_len == 0) return null;

    const out = core.castPtr(u8, core.ngx_pnalloc(pool, total_len)) orelse return null;
    var pos: usize = 0;
    var headers2 = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
    var it2 = headers2.iterator();
    while (it2.next()) |h| {
        const key = core.slicify(u8, h.*.key.data, h.*.key.len);
        const value = core.slicify(u8, h.*.value.data, h.*.value.len);
        @memcpy(out[pos..][0..key.len], key);
        pos += key.len;
        out[pos] = ':';
        out[pos + 1] = ' ';
        pos += 2;
        @memcpy(out[pos..][0..value.len], value);
        pos += value.len;
        out[pos] = '\n';
        pos += 1;
    }

    return ngx_str_t{ .data = out, .len = pos };
}

fn collectRequestHeaderNames(r: [*c]ngx_http_request_t, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_in.headers);
    var it = headers.iterator();

    var total_len: usize = 0;
    while (it.next()) |h| {
        total_len += h.*.key.len + 1;
    }
    if (total_len == 0) return null;

    const out = core.castPtr(u8, core.ngx_pnalloc(pool, total_len)) orelse return null;
    var pos: usize = 0;

    var headers2 = NList(ngx_table_elt_t).init0(&r.*.headers_in.headers);
    var it2 = headers2.iterator();
    while (it2.next()) |h| {
        const key = core.slicify(u8, h.*.key.data, h.*.key.len);
        @memcpy(out[pos..][0..key.len], key);
        pos += key.len;
        out[pos] = '\n';
        pos += 1;
    }

    return ngx_str_t{ .data = out, .len = pos };
}

fn collectRequestLine(r: [*c]ngx_http_request_t, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    if (r.*.request_line.len > 0 and r.*.request_line.data != null) {
        return dupSlice(pool, core.slicify(u8, r.*.request_line.data, r.*.request_line.len));
    }

    if (r.*.method_name.len == 0 or r.*.method_name.data == null) return null;
    if (r.*.uri.len == 0 or r.*.uri.data == null) return null;

    const method_name = core.slicify(u8, r.*.method_name.data, r.*.method_name.len);
    const uri = core.slicify(u8, r.*.uri.data, r.*.uri.len);
    const args = if (r.*.args.len > 0 and r.*.args.data != null) core.slicify(u8, r.*.args.data, r.*.args.len) else "";
    const protocol = if (r.*.http_protocol.len > 0 and r.*.http_protocol.data != null) core.slicify(u8, r.*.http_protocol.data, r.*.http_protocol.len) else "HTTP/1.1";

    const request_target_len = uri.len + (if (args.len > 0) args.len + 1 else 0);
    const total_len = method_name.len + 1 + request_target_len + 1 + protocol.len;
    const out = core.castPtr(u8, core.ngx_pnalloc(pool, total_len)) orelse return null;
    var pos: usize = 0;

    @memcpy(out[pos..][0..method_name.len], method_name);
    pos += method_name.len;
    out[pos] = ' ';
    pos += 1;

    @memcpy(out[pos..][0..uri.len], uri);
    pos += uri.len;
    if (args.len > 0) {
        out[pos] = '?';
        pos += 1;
        @memcpy(out[pos..][0..args.len], args);
        pos += args.len;
    }

    out[pos] = ' ';
    pos += 1;
    @memcpy(out[pos..][0..protocol.len], protocol);
    pos += protocol.len;

    return ngx_str_t{ .data = out, .len = pos };
}

fn collectRequestBasename(r: [*c]ngx_http_request_t, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    if (r.*.uri.len == 0 or r.*.uri.data == null) return null;

    const uri = core.slicify(u8, r.*.uri.data, r.*.uri.len);
    if (uri.len == 0) return null;

    var end = uri.len;
    while (end > 0 and uri[end - 1] == '/') : (end -= 1) {}
    if (end == 0) return null;

    const path = uri[0..end];
    const start = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| idx + 1 else 0;
    if (start >= path.len) return null;

    return dupSlice(pool, path[start..]);
}

fn collectRequestExt(r: [*c]ngx_http_request_t, pool: [*c]core.ngx_pool_t) ?ngx_str_t {
    if (r.*.exten.len == 0 or r.*.exten.data == null) return null;
    return dupSlice(pool, core.slicify(u8, r.*.exten.data, r.*.exten.len));
}

fn analyzeHeaderSelectorRules(r: [*c]ngx_http_request_t, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_in.headers);
    var it = headers.iterator();
    while (it.next()) |h| {
        const key = core.slicify(u8, h.*.key.data, h.*.key.len);
        const value = core.slicify(u8, h.*.value.data, h.*.value.len);

        var key_buf: [256]u8 = undefined;
        const key_len = @min(key.len, key_buf.len);
        @memcpy(key_buf[0..key_len], key[0..key_len]);
        toLowerSlice(key_buf[0..key_len]);

        for (0..lccf.rule_count) |i| {
            const rule: *waf_rule = @ptrCast(&lccf.rules[i]);
            if (rule.target != WAF_TARGET_REQUEST_HEADERS or rule.phase != WAF_PHASE_REQUEST or rule.selector.len == 0) continue;
            const selector = core.slicify(u8, rule.selector.data, rule.selector.len);
            if (!std.mem.eql(u8, key_buf[0..key_len], selector)) continue;

            const single = analyzeSingleRule(rule, value, decode_buf, lower_buf);
            if (single.detected) return single;
        }
    }
    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn analyzeResponseHeaderSelectorRules(r: [*c]ngx_http_request_t, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    var headers = NList(ngx_table_elt_t).init0(&r.*.headers_out.headers);
    var it = headers.iterator();
    while (it.next()) |h| {
        const key = core.slicify(u8, h.*.key.data, h.*.key.len);
        const value = core.slicify(u8, h.*.value.data, h.*.value.len);

        var key_buf: [256]u8 = undefined;
        const key_len = @min(key.len, key_buf.len);
        @memcpy(key_buf[0..key_len], key[0..key_len]);
        toLowerSlice(key_buf[0..key_len]);

        for (0..lccf.rule_count) |i| {
            const rule: *waf_rule = @ptrCast(&lccf.rules[i]);
            if (rule.target != WAF_TARGET_RESPONSE_HEADERS or rule.phase != WAF_PHASE_RESPONSE or rule.selector.len == 0) continue;
            const selector = core.slicify(u8, rule.selector.data, rule.selector.len);
            if (!std.mem.eql(u8, key_buf[0..key_len], selector)) continue;

            const single = analyzeSingleRule(rule, value, decode_buf, lower_buf);
            if (single.detected) return single;
        }
    }
    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn analyzeCookieSelectorRules(cookie_header: []const u8, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    var cookies = std.mem.splitScalar(u8, cookie_header, ';');
    while (cookies.next()) |cookie_raw| {
        const cookie = trimAscii(cookie_raw);
        if (cookie.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, cookie, '=') orelse continue;
        const name = trimAscii(cookie[0..eq]);
        const value = trimAscii(cookie[eq + 1 ..]);

        var name_buf: [256]u8 = undefined;
        const name_len = @min(name.len, name_buf.len);
        @memcpy(name_buf[0..name_len], name[0..name_len]);
        toLowerSlice(name_buf[0..name_len]);

        for (0..lccf.rule_count) |i| {
            const rule: *waf_rule = @ptrCast(&lccf.rules[i]);
            if (rule.target != WAF_TARGET_REQUEST_COOKIES or rule.phase != WAF_PHASE_REQUEST or rule.selector.len == 0) continue;
            const selector = core.slicify(u8, rule.selector.data, rule.selector.len);
            if (!std.mem.eql(u8, name_buf[0..name_len], selector)) continue;

            const single = analyzeSingleRule(rule, value, decode_buf, lower_buf);
            if (single.detected) return single;
        }
    }
    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn analyzeArgSelectorRules(args_text: []const u8, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    var args_it = std.mem.splitScalar(u8, args_text, '&');
    while (args_it.next()) |arg_raw| {
        const arg = trimAscii(arg_raw);
        if (arg.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, arg, '=') orelse continue;
        const name = trimAscii(arg[0..eq]);
        const value = trimAscii(arg[eq + 1 ..]);

        var name_buf: [256]u8 = undefined;
        const name_len = @min(name.len, name_buf.len);
        @memcpy(name_buf[0..name_len], name[0..name_len]);
        toLowerSlice(name_buf[0..name_len]);

        for (0..lccf.rule_count) |i| {
            const rule: *waf_rule = @ptrCast(&lccf.rules[i]);
            if (rule.target != WAF_TARGET_ARGS or rule.phase != WAF_PHASE_REQUEST or rule.selector.len == 0) continue;
            const selector = core.slicify(u8, rule.selector.data, rule.selector.len);
            if (!std.mem.eql(u8, name_buf[0..name_len], selector)) continue;

            const single = analyzeSingleRule(rule, value, decode_buf, lower_buf);
            if (single.detected) return single;
        }
    }
    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

fn analyzeSingleRule(rule: *waf_rule, input: []const u8, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    const normalized = applyRuleTransforms(rule, input, decode_buf, lower_buf) orelse return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
    var decoded_str = ngx_str_t{ .data = @constCast(normalized.ptr), .len = normalized.len };

    switch (rule.operator) {
        WAF_OPERATOR_CONTAINS => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (std.mem.indexOf(u8, normalized, pattern) != null) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_STRMATCH => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (std.mem.indexOf(u8, normalized, pattern) != null) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_BEGINS_WITH => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (std.mem.startsWith(u8, normalized, pattern)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_ENDS_WITH => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (std.mem.endsWith(u8, normalized, pattern)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_PM => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (phraseListMatches(normalized, pattern)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_WITHIN => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (tokenSetContains(normalized, pattern)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_LT, WAF_OPERATOR_LE, WAF_OPERATOR_GT, WAF_OPERATOR_GE => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (numericCompare(normalized, pattern, rule.operator)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_CONTAINS_WORD => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (containsWord(normalized, pattern)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_NO_MATCH => {},
        WAF_OPERATOR_UNCONDITIONAL_MATCH => {
            const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "unconditionalMatch";
            return buildRuleDetection(rule, detail);
        },
        WAF_OPERATOR_VALIDATE_URL_ENCODING => {
            if (hasInvalidUrlEncoding(input)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "validateUrlEncoding";
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_VALIDATE_UTF8_ENCODING => {
            if (!std.unicode.utf8ValidateSlice(input)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "validateUtf8Encoding";
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_IP_MATCH => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (ipMatchListContains(normalized, pattern)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_LIBINJECTION_SQLI => {
            if (libinjection.detectSqli(normalized)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "libinjection_sqli";
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_LIBINJECTION_XSS => {
            if (libinjection.detectXss(normalized)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else "libinjection_xss";
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_EQUALS => {
            const pattern = core.slicify(u8, rule.pattern.data, rule.pattern.len);
            if (std.mem.eql(u8, normalized, pattern)) {
                const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else pattern;
                return buildRuleDetection(rule, detail);
            }
        },
        WAF_OPERATOR_REGEX => {
            if (rule.compiled_regex != null) {
                const rc = regex.ngx_regex_exec(rule.compiled_regex, &decoded_str, core.nullptr(c_int), 0);
                if (rc >= 0) {
                    const detail = if (rule.msg.len > 0 and rule.msg.data != null) core.slicify(u8, rule.msg.data, rule.msg.len) else core.slicify(u8, rule.pattern.data, rule.pattern.len);
                    return buildRuleDetection(rule, detail);
                }
            }
        },
        else => {},
    }

    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

// SQL injection patterns - common attack signatures
const sqli_patterns = [_][]const u8{
    // Comment-based attacks
    "'--",
    "/*",
    "*/",
    "#'",
    // Boolean-based attacks
    "' or ",
    "' and ",
    "1=1",
    "1'='1",
    "'='",
    "or '1'='1",
    "or 1=1",
    "or true",
    // Union-based attacks
    "union select",
    "union all select",
    // Keyword-based attacks
    "select ",
    "insert ",
    "update ",
    "delete ",
    "drop ",
    "exec ",
    "execute ",
    "xp_",
    // Time-based attacks
    "sleep(",
    "waitfor delay",
    "benchmark(",
    // Other dangerous patterns
    "' or 1",
    "'; --",
    "'; drop",
    "1'; --",
};

// XSS patterns - common attack signatures
const xss_patterns = [_][]const u8{
    // Script tags and protocols
    "<script",
    "</script",
    "javascript:",
    "vbscript:",
    "data:text/html",
    // Event handlers
    "onerror=",
    "onclick=",
    "onload=",
    "onmouseover=",
    "onfocus=",
    "onblur=",
    "oninput=",
    "onchange=",
    "onsubmit=",
    "onkeydown=",
    "onkeyup=",
    "onkeypress=",
    // DOM manipulation
    "document.cookie",
    "document.write",
    "document.location",
    "window.location",
    ".innerhtml",
    // Script functions
    "alert(",
    "confirm(",
    "prompt(",
    "eval(",
    "expression(",
    "fromcharcode",
    // Other XSS vectors
    "<img",
    "<svg",
    "<iframe",
    "<object",
    "<embed",
    "<body",
    "<input",
    "<form",
    "src=",
    "href=",
};

// Decode a single hex character to value
fn hexCharToValue(c: u8) ?u8 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

// URL decode a string (handles %XX encoding)
fn urlDecode(input: []const u8, output: []u8) usize {
    var i: usize = 0;
    var j: usize = 0;
    while (i < input.len and j < output.len) {
        if (input[i] == '%' and i + 2 < input.len) {
            if (hexCharToValue(input[i + 1])) |high| {
                if (hexCharToValue(input[i + 2])) |low| {
                    output[j] = (high << 4) | low;
                    i += 3;
                    j += 1;
                    continue;
                }
            }
        }
        if (input[i] == '+') {
            output[j] = ' ';
        } else {
            output[j] = input[i];
        }
        i += 1;
        j += 1;
    }
    return j;
}

// Convert a byte to lowercase
fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

// Convert slice to lowercase in-place
fn toLowerSlice(slice: []u8) void {
    for (slice) |*c| {
        c.* = toLower(c.*);
    }
}

// Check for SQL injection patterns
fn checkSqli(input: []const u8) ?[]const u8 {
    for (sqli_patterns) |pattern| {
        if (std.mem.indexOf(u8, input, pattern) != null) {
            return pattern;
        }
    }
    return null;
}

// Check for XSS patterns
fn checkXss(input: []const u8) ?[]const u8 {
    for (xss_patterns) |pattern| {
        if (std.mem.indexOf(u8, input, pattern) != null) {
            return pattern;
        }
    }
    return null;
}

// Analyze input for attacks
fn analyzeInput(input: []const u8, lccf: *waf_loc_conf, decode_buf: []u8, lower_buf: []u8) DetectionResult {
    // First, URL decode the input
    const decoded_len = urlDecode(input, decode_buf);
    if (decoded_len == 0) {
        return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
    }

    // Convert to lowercase for case-insensitive matching
    const actual_len = @min(decoded_len, lower_buf.len);
    @memcpy(lower_buf[0..actual_len], decode_buf[0..actual_len]);
    toLowerSlice(lower_buf[0..actual_len]);

    const normalized = lower_buf[0..actual_len];
    const decoded = decode_buf[0..actual_len];

    // Check for SQL injection
    if (lccf.sqli_enabled == 1) {
        if (libinjection.detectSqli(decoded)) {
            return DetectionResult{ .detected = true, .rule_type = "sqli", .pattern = "libinjection", .status = http.NGX_HTTP_FORBIDDEN };
        }
        if (checkSqli(normalized)) |pattern| {
            return DetectionResult{ .detected = true, .rule_type = "sqli", .pattern = pattern, .status = http.NGX_HTTP_FORBIDDEN };
        }
    }

    // Check for XSS
    if (lccf.xss_enabled == 1) {
        if (libinjection.detectXss(decoded)) {
            return DetectionResult{ .detected = true, .rule_type = "xss", .pattern = "libinjection", .status = http.NGX_HTTP_FORBIDDEN };
        }
        if (checkXss(normalized)) |pattern| {
            return DetectionResult{ .detected = true, .rule_type = "xss", .pattern = pattern, .status = http.NGX_HTTP_FORBIDDEN };
        }
    }

    return DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN };
}

// Send blocked response
fn sendBlockedResponse(r: [*c]ngx_http_request_t, rule_type: []const u8, status: ngx_uint_t) ngx_int_t {
    // Set content type
    const content_type = ngx_string("application/json");
    r.*.headers_out.content_type = content_type;
    r.*.headers_out.content_type_len = content_type.len;
    r.*.headers_out.status = @intCast(status);

    // Build error response: {"error":"waf_blocked","rule":"<type>"}
    const prefix = "{\"error\":\"waf_blocked\",\"rule\":\"";
    const suffix = "\"}";
    const response_len = prefix.len + rule_type.len + suffix.len;

    const buf_mem = core.ngx_pnalloc(r.*.pool, response_len) orelse return NGX_ERROR;
    const buf_ptr = core.castPtr(u8, buf_mem) orelse return NGX_ERROR;
    const response_buf = core.slicify(u8, buf_ptr, response_len);

    @memcpy(response_buf[0..prefix.len], prefix);
    @memcpy(response_buf[prefix.len..][0..rule_type.len], rule_type);
    @memcpy(response_buf[prefix.len + rule_type.len ..][0..suffix.len], suffix);

    r.*.headers_out.content_length_n = @intCast(response_len);

    const header_rc = http.ngx_http_send_header(r);
    if (header_rc == NGX_ERROR or header_rc > NGX_OK) {
        return header_rc;
    }

    // Create output buffer
    const b = core.castPtr(ngx_buf_t, core.ngx_pcalloc(r.*.pool, @sizeOf(ngx_buf_t))) orelse return NGX_ERROR;

    b.*.pos = buf_ptr;
    b.*.last = buf_ptr + response_len;
    b.*.flags.memory = true;
    b.*.flags.last_buf = (r == r.*.main);
    b.*.flags.last_in_chain = true;

    if (r.*.flags1.header_only) {
        return http.ngx_http_send_special(r, http.NGX_HTTP_LAST);
    }

    var out: ngx_chain_t = undefined;
    out.buf = b;
    out.next = null;

    return http.ngx_http_output_filter(r, &out);
}

// Log detection without blocking
fn logDetection(r: [*c]ngx_http_request_t, rule_type: []const u8, pattern: []const u8, tag: []const u8, logdata: []const u8) void {
    var msg_buf: [384]u8 = undefined;
    const message = if (tag.len > 0 and logdata.len > 0 and pattern.len > 0)
        std.fmt.bufPrintZ(&msg_buf, "WAF: {s} rule matched: {s}; tag={s}; logdata={s}", .{ rule_type, pattern, tag, logdata }) catch "WAF: rule matched"
    else if (tag.len > 0 and pattern.len > 0)
        std.fmt.bufPrintZ(&msg_buf, "WAF: {s} rule matched: {s}; tag={s}", .{ rule_type, pattern, tag }) catch "WAF: rule matched"
    else if (logdata.len > 0 and pattern.len > 0)
        std.fmt.bufPrintZ(&msg_buf, "WAF: {s} rule matched: {s}; logdata={s}", .{ rule_type, pattern, logdata }) catch "WAF: rule matched"
    else if (pattern.len > 0)
        std.fmt.bufPrintZ(&msg_buf, "WAF: {s} rule matched: {s}", .{ rule_type, pattern }) catch "WAF: rule matched"
    else
        std.fmt.bufPrintZ(&msg_buf, "WAF: {s} rule matched", .{rule_type}) catch "WAF: rule matched";
    ngx.log.ngz_log_error(ngx.log.NGX_LOG_WARN, r.*.connection.*.log, 0, message.ptr, .{});
}

fn finalizeBlockedRequest(r: [*c]ngx_http_request_t, rctx: *waf_ctx, rule_type: []const u8, status: ngx_uint_t) ngx_int_t {
    if (rctx.*.waf_result != WAF_RESULT_DENIED) {
        rctx.*.waf_result = WAF_RESULT_DENIED;
        rctx.*.waf_category = ngx_string(rule_type);
    }
    rctx.*.done = 1;
    rctx.*.finalized = 1;
    const blocked_after_body = rctx.*.waiting_body == 1;
    rctx.*.waiting_body = 0;
    // Body-phase denials do not continue to a content handler.  Advertise a
    // normal connection close so a client pool cannot reuse body-buffer state,
    // but do not force nginx's lingering-close path: that path can race the
    // next pooled fetch and surface as ECONNRESET.
    if (blocked_after_body) r.*.flags1.keepalive = false;

    const rc = sendBlockedResponse(r, rule_type, status);
    http.ngx_http_finalize_request(r, rc);
    return NGX_DONE;
}

export fn ngx_http_waf_header_filter(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        waf_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_waf_module),
    ) orelse {
        if (ngx_http_waf_next_header_filter) |next| return next(r);
        return NGX_OK;
    };

    if (lccf.*.enabled != 1 or lccf.*.rule_count == 0) {
        if (ngx_http_waf_next_header_filter) |next| return next(r);
        return NGX_OK;
    }

    const decode_buf_mem = core.ngx_pnalloc(r.*.pool, 4096) orelse return NGX_ERROR;
    const decode_buf = core.slicify(u8, core.castPtr(u8, decode_buf_mem) orelse return NGX_ERROR, 4096);
    const lower_buf_mem = core.ngx_pnalloc(r.*.pool, 4096) orelse return NGX_ERROR;
    const lower_buf = core.slicify(u8, core.castPtr(u8, lower_buf_mem) orelse return NGX_ERROR, 4096);

    var status_buf: [32]u8 = undefined;
    const status_text = std.fmt.bufPrint(&status_buf, "{d}", .{r.*.headers_out.status}) catch "";
    const status_result = analyzeCustomRules(status_text, WAF_TARGET_RESPONSE_STATUS, WAF_PHASE_RESPONSE, lccf, decode_buf, lower_buf);
    if (status_result.detected) {
        const disposition = resolveMatchDisposition(status_result, lccf);
        if (disposition.block) {
            r.*.headers_out.status = @intCast(status_result.status);
            r.*.headers_out.content_length_n = 0;
        } else if (disposition.log) {
            logDetection(r, status_result.rule_type, status_result.pattern, status_result.tag, status_result.logdata);
        }
    }

    const header_selector_result = analyzeResponseHeaderSelectorRules(r, lccf, decode_buf, lower_buf);
    if (header_selector_result.detected) {
        const disposition = resolveMatchDisposition(header_selector_result, lccf);
        if (disposition.block) {
            r.*.headers_out.status = @intCast(header_selector_result.status);
            r.*.headers_out.content_length_n = 0;
        } else if (disposition.log) {
            logDetection(r, header_selector_result.rule_type, header_selector_result.pattern, header_selector_result.tag, header_selector_result.logdata);
        }
    }

    if (collectResponseHeaders(r, r.*.pool)) |headers_text| {
        const headers_slice = core.slicify(u8, headers_text.data, headers_text.len);
        const headers_result = analyzeCustomRules(headers_slice, WAF_TARGET_RESPONSE_HEADERS, WAF_PHASE_RESPONSE, lccf, decode_buf, lower_buf);
        if (headers_result.detected) {
            const disposition = resolveMatchDisposition(headers_result, lccf);
            if (disposition.block) {
                r.*.headers_out.status = @intCast(headers_result.status);
                r.*.headers_out.content_length_n = 0;
            } else if (disposition.log) {
                logDetection(r, headers_result.rule_type, headers_result.pattern, headers_result.tag, headers_result.logdata);
            }
        }
    }

    if (ngx_http_waf_next_header_filter) |next| return next(r);
    return NGX_OK;
}

// Body handler - called after request body is read
export fn ngx_http_waf_body_handler(r: [*c]ngx_http_request_t) callconv(.c) void {
    const rctx = core.castPtr(waf_ctx, r.*.ctx[ngx_http_waf_module.ctx_index]) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };

    const lccf = rctx.*.lccf;

    // Check if request body exists
    if (r.*.request_body == null or r.*.request_body.*.bufs == null) {
        rctx.*.waiting_body = 0;
        rctx.*.done = 1;
        r.*.write_event_handler = http.ngx_http_core_run_phases;
        http.ngx_http_core_run_phases(r);
        return;
    }

    // Collect request body into a single buffer
    var body_len: usize = 0;
    var chain = r.*.request_body.*.bufs;
    while (chain != null) : (chain = chain.*.next) {
        if (chain.*.buf != null) {
            const b = chain.*.buf;
            body_len += @intFromPtr(b.*.last) - @intFromPtr(b.*.pos);
        }
    }

    if (body_len == 0) {
        rctx.*.waiting_body = 0;
        rctx.*.done = 1;
        r.*.write_event_handler = http.ngx_http_core_run_phases;
        http.ngx_http_core_run_phases(r);
        return;
    }

    // Allocate body buffer
    const body_buf = core.ngx_pnalloc(r.*.pool, body_len) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };
    const body_ptr = core.castPtr(u8, body_buf) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };

    // Copy body data
    var offset: usize = 0;
    chain = r.*.request_body.*.bufs;
    while (chain != null) : (chain = chain.*.next) {
        if (chain.*.buf != null) {
            const b = chain.*.buf;
            const chunk_len = @intFromPtr(b.*.last) - @intFromPtr(b.*.pos);
            if (chunk_len > 0) {
                @memcpy(body_ptr[offset..][0..chunk_len], core.slicify(u8, b.*.pos, chunk_len));
                offset += chunk_len;
            }
        }
    }

    const body = core.slicify(u8, body_ptr, body_len);

    // Allocate buffers for analysis (limit to reasonable size)
    const max_analyze_len: usize = 8192;
    const analyze_len = @min(body_len, max_analyze_len);

    const decode_buf_mem = core.ngx_pnalloc(r.*.pool, analyze_len * 2) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };
    const decode_buf = core.slicify(u8, core.castPtr(u8, decode_buf_mem) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    }, analyze_len * 2);

    const lower_buf_mem = core.ngx_pnalloc(r.*.pool, analyze_len * 2) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    };
    const lower_buf = core.slicify(u8, core.castPtr(u8, lower_buf_mem) orelse {
        http.ngx_http_finalize_request(r, NGX_ERROR);
        return;
    }, analyze_len * 2);

    const body_selector_result = analyzeBodySelectorRules(r, body[0..analyze_len], lccf, decode_buf, lower_buf);
    if (body_selector_result.detected) {
        if (handleDetection(r, rctx, lccf, body_selector_result)) |_| return;
    }

    // Analyze request body
    const result = analyzeInput(body[0..analyze_len], lccf, decode_buf, lower_buf);
    const custom_result = if (result.detected)
        DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN }
    else
        analyzeCustomRules(body[0..analyze_len], WAF_TARGET_REQUEST_BODY, WAF_PHASE_BODY, lccf, decode_buf, lower_buf);
    const final_result = if (result.detected) result else custom_result;

    if (final_result.detected) {
        if (handleDetection(r, rctx, lccf, final_result)) |_| return;
    }

    // Continue to next phase
    rctx.*.waiting_body = 0;
    rctx.*.done = 1;
    r.*.write_event_handler = http.ngx_http_core_run_phases;
    http.ngx_http_core_run_phases(r);
}

// handleDetection dispatches a single detection result: records in ctx, calls
// finalizeBlockedRequest (denied) or logDetection (dryrun). Returns the rc to
// propagate when blocked, null when the request continues.
inline fn handleDetection(
    r: [*c]ngx_http_request_t,
    rctx: *waf_ctx,
    lccf: *waf_loc_conf,
    result: DetectionResult,
) ?ngx_int_t {
    const disposition = resolveMatchDisposition(result, lccf);
    recordOffense(r, lccf, result.score_weight);
    if (disposition.block) {
        rctx.*.waf_result = WAF_RESULT_DENIED;
        rctx.*.waf_rule_id = result.rule_id;
        rctx.*.waf_category = ngx_string(result.rule_type);
        return finalizeBlockedRequest(r, rctx, result.rule_type, result.status);
    }
    if (disposition.log) {
        if (rctx.*.waf_result == WAF_RESULT_ALLOWED) {
            rctx.*.waf_result = WAF_RESULT_DRYRUN;
            rctx.*.waf_rule_id = result.rule_id;
            rctx.*.waf_category = ngx_string(result.rule_type);
        }
        logDetection(r, result.rule_type, result.pattern, result.tag, result.logdata);
    }
    return null;
}

// Access phase handler
export fn ngx_http_waf_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    const lccf = core.castPtr(
        waf_loc_conf,
        conf.ngx_http_get_module_loc_conf(r, &ngx_http_waf_module),
    ) orelse return NGX_DECLINED;

    if (lccf.*.enabled != 1) {
        return NGX_DECLINED;
    }

    // Skip if neither built-in detectors nor file-driven rules are enabled
    if (lccf.*.sqli_enabled != 1 and lccf.*.xss_enabled != 1 and lccf.*.rule_count == 0) {
        return NGX_DECLINED;
    }

    // Check if we've already processed this request
    const rctx = http.ngz_http_get_module_ctx(
        waf_ctx,
        r,
        &ngx_http_waf_module,
    ) catch return http.NGX_HTTP_INTERNAL_SERVER_ERROR;

    if (rctx.*.done == 1) {
        return NGX_DECLINED;
    }
    rctx.*.lccf = lccf;

    if (isClientBanned(r, lccf)) {
        return finalizeBlockedRequest(r, rctx, "ban", http.NGX_HTTP_FORBIDDEN);
    }

    // Allocate buffers for analysis
    const max_uri_len: usize = 4096;
    const decode_buf_mem = core.ngx_pnalloc(r.*.pool, max_uri_len) orelse return NGX_ERROR;
    const decode_buf = core.slicify(u8, core.castPtr(u8, decode_buf_mem) orelse return NGX_ERROR, max_uri_len);

    const lower_buf_mem = core.ngx_pnalloc(r.*.pool, max_uri_len) orelse return NGX_ERROR;
    const lower_buf = core.slicify(u8, core.castPtr(u8, lower_buf_mem) orelse return NGX_ERROR, max_uri_len);

    // Check URI
    if (r.*.uri.len > 0 and r.*.uri.data != null) {
        const uri = core.slicify(u8, r.*.uri.data, r.*.uri.len);
        const uri_result = analyzeInput(uri, lccf, decode_buf, lower_buf);
        const uri_custom_result = if (uri_result.detected)
            DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN }
        else
            analyzeCustomRules(uri, WAF_TARGET_REQUEST_URI, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        const final_uri_result = if (uri_result.detected) uri_result else uri_custom_result;
        if (final_uri_result.detected) {
            if (handleDetection(r, rctx, lccf, final_uri_result)) |rc| return rc;
        }
    }

    // Check query string (args)
    if (r.*.args.len > 0 and r.*.args.data != null) {
        const args = core.slicify(u8, r.*.args.data, r.*.args.len);
        const args_selector_result = analyzeArgSelectorRules(args, lccf, decode_buf, lower_buf);
        if (args_selector_result.detected) {
            if (handleDetection(r, rctx, lccf, args_selector_result)) |rc| return rc;
        }

        const args_result = analyzeInput(args, lccf, decode_buf, lower_buf);
        const args_custom_result = if (args_result.detected)
            DetectionResult{ .detected = false, .rule_type = "", .pattern = "", .status = http.NGX_HTTP_FORBIDDEN }
        else
            analyzeCustomRules(args, WAF_TARGET_ARGS, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        const final_args_result = if (args_result.detected) args_result else args_custom_result;
        if (final_args_result.detected) {
            if (handleDetection(r, rctx, lccf, final_args_result)) |rc| return rc;
        }
    }

    if (r.*.headers_in.cookie != core.nullptr(ngx_table_elt_t)) {
        const cookie_value = r.*.headers_in.cookie.*.value;
        if (cookie_value.len > 0 and cookie_value.data != null) {
            const cookies = core.slicify(u8, cookie_value.data, cookie_value.len);
            const cookie_selector_result = analyzeCookieSelectorRules(cookies, lccf, decode_buf, lower_buf);
            if (cookie_selector_result.detected) {
                if (handleDetection(r, rctx, lccf, cookie_selector_result)) |rc| return rc;
            }
            const cookie_result = analyzeCustomRules(cookies, WAF_TARGET_REQUEST_COOKIES, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
            if (cookie_result.detected) {
                if (handleDetection(r, rctx, lccf, cookie_result)) |rc| return rc;
            }
        }
    }

    if (r.*.method_name.len > 0 and r.*.method_name.data != null) {
        const method_name = core.slicify(u8, r.*.method_name.data, r.*.method_name.len);
        const method_result = analyzeCustomRules(method_name, WAF_TARGET_REQUEST_METHOD, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (method_result.detected) {
            if (handleDetection(r, rctx, lccf, method_result)) |rc| return rc;
        }
    }

    if (r.*.connection != null and r.*.connection.*.addr_text.len > 0 and r.*.connection.*.addr_text.data != null) {
        const remote_addr = core.slicify(u8, r.*.connection.*.addr_text.data, r.*.connection.*.addr_text.len);
        const addr_result = analyzeCustomRules(remote_addr, WAF_TARGET_REMOTE_ADDR, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (addr_result.detected) {
            if (handleDetection(r, rctx, lccf, addr_result)) |rc| return rc;
        }
    }

    if (r.*.args.len > 0 and r.*.args.data != null) {
        const query_string = core.slicify(u8, r.*.args.data, r.*.args.len);
        const query_result = analyzeCustomRules(query_string, WAF_TARGET_QUERY_STRING, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (query_result.detected) {
            if (handleDetection(r, rctx, lccf, query_result)) |rc| return rc;
        }
    }

    if (collectRequestLine(r, r.*.pool)) |request_line| {
        const request_line_slice = core.slicify(u8, request_line.data, request_line.len);
        const request_line_result = analyzeCustomRules(request_line_slice, WAF_TARGET_REQUEST_LINE, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (request_line_result.detected) {
            if (handleDetection(r, rctx, lccf, request_line_result)) |rc| return rc;
        }
    }

    if (r.*.http_protocol.len > 0 and r.*.http_protocol.data != null) {
        const request_protocol = core.slicify(u8, r.*.http_protocol.data, r.*.http_protocol.len);
        const protocol_result = analyzeCustomRules(request_protocol, WAF_TARGET_REQUEST_PROTOCOL, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (protocol_result.detected) {
            if (handleDetection(r, rctx, lccf, protocol_result)) |rc| return rc;
        }
    }

    const request_scheme = if (r.*.connection != null and r.*.connection.*.ssl != null) "https" else "http";
    const scheme_result = analyzeCustomRules(request_scheme, WAF_TARGET_REQUEST_SCHEME, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
    if (scheme_result.detected) {
        if (handleDetection(r, rctx, lccf, scheme_result)) |rc| return rc;
    }

    if (collectRequestBasename(r, r.*.pool)) |request_basename| {
        const basename_slice = core.slicify(u8, request_basename.data, request_basename.len);
        const basename_result = analyzeCustomRules(basename_slice, WAF_TARGET_REQUEST_BASENAME, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (basename_result.detected) {
            if (handleDetection(r, rctx, lccf, basename_result)) |rc| return rc;
        }
    }

    if (collectRequestExt(r, r.*.pool)) |request_ext| {
        const ext_slice = core.slicify(u8, request_ext.data, request_ext.len);
        const ext_result = analyzeCustomRules(ext_slice, WAF_TARGET_REQUEST_EXT, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (ext_result.detected) {
            if (handleDetection(r, rctx, lccf, ext_result)) |rc| return rc;
        }
    }

    const header_selector_result = analyzeHeaderSelectorRules(r, lccf, decode_buf, lower_buf);
    if (header_selector_result.detected) {
        if (handleDetection(r, rctx, lccf, header_selector_result)) |rc| return rc;
    }

    if (collectRequestHeaders(r, r.*.pool)) |headers_text| {
        const headers_slice = core.slicify(u8, headers_text.data, headers_text.len);
        const headers_result = analyzeCustomRules(headers_slice, WAF_TARGET_REQUEST_HEADERS, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (headers_result.detected) {
            if (handleDetection(r, rctx, lccf, headers_result)) |rc| return rc;
        }
    }

    if (collectRequestHeaderNames(r, r.*.pool)) |header_names_text| {
        const header_names_slice = core.slicify(u8, header_names_text.data, header_names_text.len);
        const header_names_result = analyzeCustomRules(header_names_slice, WAF_TARGET_REQUEST_HEADER_NAMES, WAF_PHASE_REQUEST, lccf, decode_buf, lower_buf);
        if (header_names_result.detected) {
            if (handleDetection(r, rctx, lccf, header_names_result)) |rc| return rc;
        }
    }

    // Check request body for POST/PUT/PATCH if enabled
    if (lccf.*.check_body == 1 or hasBodyRules(lccf)) {
        if (r.*.method == http.NGX_HTTP_POST or
            r.*.method == http.NGX_HTTP_PUT or
            r.*.method == http.NGX_HTTP_PATCH)
        {
            rctx.*.waiting_body = 1;
            const rc = http.ngx_http_read_client_request_body(r, ngx_http_waf_body_handler);
            if (rc >= http.NGX_HTTP_SPECIAL_RESPONSE) return rc;
            http.ngx_http_finalize_request(r, NGX_DONE);
            return NGX_DONE;
        }
    }

    rctx.*.done = 1;
    return NGX_DECLINED;
}

fn create_loc_conf(cf: [*c]ngx_conf_t) callconv(.c) ?*anyopaque {
    if (core.ngz_pcalloc_c(waf_loc_conf, cf.*.pool)) |p| {
        p.*.enabled = conf.NGX_CONF_UNSET;
        p.*.mode = WAF_MODE_BLOCK; // Default to block mode
        p.*.sqli_enabled = conf.NGX_CONF_UNSET;
        p.*.xss_enabled = conf.NGX_CONF_UNSET;
        p.*.check_body = conf.NGX_CONF_UNSET;
        p.*.rules_file = ngx_str_t{ .len = 0, .data = core.nullptr(u8) };
        p.*.rules = core.nullptr(waf_rule);
        p.*.rule_count = 0;
        p.*.ban_threshold = conf.NGX_CONF_UNSET_UINT;
        p.*.ban_window = conf.NGX_CONF_UNSET_UINT;
        p.*.ban_duration = conf.NGX_CONF_UNSET_UINT;
        p.*.score_threshold = conf.NGX_CONF_UNSET_UINT;
        p.*.score_decay_window = conf.NGX_CONF_UNSET_UINT;
        return p;
    }
    return null;
}

fn merge_loc_conf(
    cf: [*c]ngx_conf_t,
    parent: ?*anyopaque,
    child: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cf;
    const prev = core.castPtr(waf_loc_conf, parent) orelse return conf.NGX_CONF_OK;
    const c = core.castPtr(waf_loc_conf, child) orelse return conf.NGX_CONF_OK;

    // Inherit enabled flag
    const child_enabled_unset = c.*.enabled == conf.NGX_CONF_UNSET;
    if (c.*.enabled == conf.NGX_CONF_UNSET) {
        c.*.enabled = if (prev.*.enabled == conf.NGX_CONF_UNSET) 0 else prev.*.enabled;
    }

    // Inherit mode if child did not explicitly set waf on/off and parent was enabled
    if (prev.*.enabled == 1 and child_enabled_unset) {
        c.*.mode = prev.*.mode;
    }

    // Inherit sqli_enabled
    if (c.*.sqli_enabled == conf.NGX_CONF_UNSET) {
        c.*.sqli_enabled = if (prev.*.sqli_enabled == conf.NGX_CONF_UNSET) 1 else prev.*.sqli_enabled;
    }

    // Inherit xss_enabled
    if (c.*.xss_enabled == conf.NGX_CONF_UNSET) {
        c.*.xss_enabled = if (prev.*.xss_enabled == conf.NGX_CONF_UNSET) 1 else prev.*.xss_enabled;
    }

    // Inherit check_body
    if (c.*.check_body == conf.NGX_CONF_UNSET) {
        c.*.check_body = if (prev.*.check_body == conf.NGX_CONF_UNSET) 0 else prev.*.check_body;
    }

    if (c.*.rules_file.len == 0) {
        c.*.rules_file = prev.*.rules_file;
        c.*.rules = prev.*.rules;
        c.*.rule_count = prev.*.rule_count;
    }

    if (c.*.ban_threshold == conf.NGX_CONF_UNSET_UINT) {
        c.*.ban_threshold = if (prev.*.ban_threshold == conf.NGX_CONF_UNSET_UINT) 0 else prev.*.ban_threshold;
    }
    if (c.*.ban_window == conf.NGX_CONF_UNSET_UINT) {
        c.*.ban_window = if (prev.*.ban_window == conf.NGX_CONF_UNSET_UINT) 60 else prev.*.ban_window;
    }
    if (c.*.ban_duration == conf.NGX_CONF_UNSET_UINT) {
        c.*.ban_duration = if (prev.*.ban_duration == conf.NGX_CONF_UNSET_UINT) 300 else prev.*.ban_duration;
    }
    if (c.*.score_threshold == conf.NGX_CONF_UNSET_UINT) {
        c.*.score_threshold = if (prev.*.score_threshold == conf.NGX_CONF_UNSET_UINT) 0 else prev.*.score_threshold;
    }
    if (c.*.score_decay_window == conf.NGX_CONF_UNSET_UINT) {
        c.*.score_decay_window = if (prev.*.score_decay_window == conf.NGX_CONF_UNSET_UINT)
            WAF_DEFAULT_SCORE_DECAY_WINDOW
        else
            prev.*.score_decay_window;
    }

    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_waf_rules_file(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            var path = arg.*;
            if (conf.ngx_conf_full_name(cf.*.cycle, &path, 1) != core.NGX_OK) {
                return conf.NGX_CONF_ERROR;
            }

            const contents = file.ngz_open_file(path, cf.*.log, cf.*.pool) catch return conf.NGX_CONF_ERROR;
            var rules_ptr: [*c]waf_rule = core.nullptr(waf_rule);
            var rule_count: usize = 0;
            var load_error: ?RuleLoadError = null;
            if (!loadWafRules(contents, cf.*.pool, cf, &rules_ptr, &rule_count, &load_error)) {
                if (load_error) |err| {
                    var err_buf: [512]u8 = undefined;
                    const path_slice = core.slicify(u8, path.data, path.len);
                    const message = std.fmt.bufPrintZ(&err_buf, "waf_rules_file {s} line {d}: {s}", .{ path_slice, err.line_no, err.reason }) catch "invalid waf_rules_file";
                    ngx.log.ngz_log_error(ngx.log.NGX_LOG_EMERG, cf.*.log, 0, message.ptr, .{});
                }
                return conf.NGX_CONF_ERROR;
            }

            lccf.*.enabled = 1;
            lccf.*.rules_file = path;
            lccf.*.rules = rules_ptr;
            lccf.*.rule_count = rule_count;
        }
    }
    return conf.NGX_CONF_OK;
}

// Set waf on|off
fn ngx_conf_set_waf(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, value, "on")) {
                lccf.*.enabled = 1;
            } else if (std.mem.eql(u8, value, "off")) {
                lccf.*.enabled = 0;
            } else {
                return conf.NGX_CONF_ERROR;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

// Set waf_mode detect|block
fn ngx_conf_set_waf_mode(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, value, "detect")) {
                lccf.*.mode = WAF_MODE_DETECT;
            } else if (std.mem.eql(u8, value, "block")) {
                lccf.*.mode = WAF_MODE_BLOCK;
            } else {
                return conf.NGX_CONF_ERROR;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

// Set waf_sqli on|off
fn ngx_conf_set_waf_sqli(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, value, "on")) {
                lccf.*.sqli_enabled = 1;
            } else if (std.mem.eql(u8, value, "off")) {
                lccf.*.sqli_enabled = 0;
            } else {
                return conf.NGX_CONF_ERROR;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

// Set waf_xss on|off
fn ngx_conf_set_waf_xss(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, value, "on")) {
                lccf.*.xss_enabled = 1;
            } else if (std.mem.eql(u8, value, "off")) {
                lccf.*.xss_enabled = 0;
            } else {
                return conf.NGX_CONF_ERROR;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

// Set waf_check_body on|off
fn ngx_conf_set_waf_check_body(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            if (std.mem.eql(u8, value, "on")) {
                lccf.*.check_body = 1;
            } else if (std.mem.eql(u8, value, "off")) {
                lccf.*.check_body = 0;
            } else {
                return conf.NGX_CONF_ERROR;
            }
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_waf_ban_threshold(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.ban_threshold = std.fmt.parseInt(ngx_uint_t, value, 10) catch return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_waf_ban_window(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.ban_window = std.fmt.parseInt(ngx_uint_t, value, 10) catch return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_waf_ban_duration(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.ban_duration = std.fmt.parseInt(ngx_uint_t, value, 10) catch return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_waf_score_threshold(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.score_threshold = std.fmt.parseInt(ngx_uint_t, value, 10) catch return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

fn ngx_conf_set_waf_score_decay_window(
    cf: [*c]ngx_conf_t,
    cmd: [*c]ngx_command_t,
    loc: ?*anyopaque,
) callconv(.c) [*c]u8 {
    _ = cmd;
    if (core.castPtr(waf_loc_conf, loc)) |lccf| {
        var i: ngx_uint_t = 1;
        if (ngx.array.ngx_array_next(ngx_str_t, cf.*.args, &i)) |arg| {
            const value = core.slicify(u8, arg.*.data, arg.*.len);
            lccf.*.score_decay_window = std.fmt.parseInt(ngx_uint_t, value, 10) catch return conf.NGX_CONF_ERROR;
        }
    }
    return conf.NGX_CONF_OK;
}

const ngx_http_variable_value_t = http.ngx_http_variable_value_t;

fn ngx_http_waf_result_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const rctx = core.castPtr(waf_ctx, r.*.ctx[ngx_http_waf_module.ctx_index]) orelse {
        v.*.data = @constCast("allowed");
        v.*.flags.len = 7;
        v.*.flags.valid = true;
        v.*.flags.no_cacheable = true;
        v.*.flags.not_found = false;
        return NGX_OK;
    };
    const result_str: []const u8 = switch (rctx.*.waf_result) {
        WAF_RESULT_DENIED => "denied",
        WAF_RESULT_DRYRUN => "dryrun",
        else => "allowed",
    };
    v.*.data = @constCast(result_str.ptr);
    v.*.flags.len = @intCast(result_str.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn ngx_http_waf_rule_id_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const rctx = core.castPtr(waf_ctx, r.*.ctx[ngx_http_waf_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (rctx.*.waf_rule_id == 0) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    var num_buf: [24]u8 = undefined;
    const slice = std.fmt.bufPrint(&num_buf, "{d}", .{rctx.*.waf_rule_id}) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    const copied = ngx.string.ngx_string_from_pool(@constCast(slice.ptr), slice.len, r.*.pool) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    v.*.data = copied.data;
    v.*.flags.len = @intCast(copied.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn ngx_http_waf_score_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    var score: u16 = 0;
    const rctx = core.castPtr(waf_ctx, r.*.ctx[ngx_http_waf_module.ctx_index]);
    if (rctx != null) {
        const lccf = rctx.?.*.lccf;
        if (lccf != core.nullptr(waf_loc_conf) and lccf.*.score_threshold > 0) {
            if (getClientIp(r)) |ip| {
                const zone = ngx_http_waf_ban_zone;
                if (zone != core.nullptr(core.ngx_shm_zone_t) and zone.*.shm.addr != null) {
                    if (core.castPtr(core.ngx_slab_pool_t, zone.*.shm.addr)) |shpool| {
                        shm.ngx_shmtx_lock(&shpool.*.mutex);
                        if (getBanStore()) |store| {
                            if (findBanEntry(store, ip, policyScope(lccf))) |entry| {
                                score = entry.*.score;
                            }
                        }
                        shm.ngx_shmtx_unlock(&shpool.*.mutex);
                    }
                }
            }
        }
    }
    var score_buf: [8]u8 = undefined;
    const slice = std.fmt.bufPrint(&score_buf, "{d}", .{score}) catch "0";
    const copied = ngx.string.ngx_string_from_pool(@constCast(slice.ptr), slice.len, r.*.pool) catch {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    v.*.data = copied.data;
    v.*.flags.len = @intCast(copied.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn ngx_http_waf_category_variable(
    r: [*c]ngx_http_request_t,
    v: [*c]ngx_http_variable_value_t,
    data: core.uintptr_t,
) callconv(.c) ngx_int_t {
    _ = data;
    const rctx = core.castPtr(waf_ctx, r.*.ctx[ngx_http_waf_module.ctx_index]) orelse {
        v.*.flags.not_found = true;
        return NGX_OK;
    };
    if (rctx.*.waf_category.len == 0 or rctx.*.waf_category.data == null) {
        v.*.flags.not_found = true;
        return NGX_OK;
    }
    v.*.data = rctx.*.waf_category.data;
    v.*.flags.len = @intCast(rctx.*.waf_category.len);
    v.*.flags.valid = true;
    v.*.flags.no_cacheable = true;
    v.*.flags.not_found = false;
    return NGX_OK;
}

fn postconfiguration(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    var zone_name = ngx_string("waf_ban_zone");
    const zone = shm.ngx_shared_memory_add(cf, &zone_name, WAF_BAN_ZONE_SIZE, @constCast(&ngx_http_waf_module));
    if (zone == core.nullptr(core.ngx_shm_zone_t)) return NGX_ERROR;
    zone.*.init = ngx_http_waf_ban_zone_init;
    ngx_http_waf_ban_zone = zone;

    var vs = [_]http.ngx_http_variable_t{
        http.ngx_http_variable_t{ .name = ngx_string("waf_result"), .set_handler = null, .get_handler = ngx_http_waf_result_variable, .data = 0, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("waf_rule_id"), .set_handler = null, .get_handler = ngx_http_waf_rule_id_variable, .data = 0, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("waf_score"), .set_handler = null, .get_handler = ngx_http_waf_score_variable, .data = 0, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
        http.ngx_http_variable_t{ .name = ngx_string("waf_category"), .set_handler = null, .get_handler = ngx_http_waf_category_variable, .data = 0, .flags = http.NGX_HTTP_VAR_NOCACHEABLE, .index = 0 },
    };
    for (&vs) |*v| {
        if (http.ngx_http_add_variable(cf, &v.name, v.flags)) |x| {
            x.*.get_handler = v.get_handler;
            x.*.data = v.data;
        }
    }

    // Register access phase handler
    const cmcf = core.castPtr(
        http.ngx_http_core_main_conf_t,
        conf.ngx_http_conf_get_module_main_conf(cf, &ngx_http_core_module),
    ) orelse return NGX_ERROR;

    var handlers = NArray(http.ngx_http_handler_pt).init0(
        &cmcf[0].phases[http.NGX_HTTP_ACCESS_PHASE].handlers,
    );
    const h = handlers.append() catch return NGX_ERROR;
    h.* = ngx_http_waf_handler;

    return NGX_OK;
}

fn postconfiguration_filter(cf: [*c]ngx_conf_t) callconv(.c) ngx_int_t {
    _ = cf;
    ngx_http_waf_next_header_filter = http.ngx_http_top_header_filter;
    http.ngx_http_top_header_filter = ngx_http_waf_header_filter;
    return NGX_OK;
}

export const ngx_http_waf_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = create_loc_conf,
    .merge_loc_conf = merge_loc_conf,
};

export const ngx_http_waf_filter_module_ctx = ngx_http_module_t{
    .preconfiguration = null,
    .postconfiguration = postconfiguration_filter,
    .create_main_conf = null,
    .init_main_conf = null,
    .create_srv_conf = null,
    .merge_srv_conf = null,
    .create_loc_conf = null,
    .merge_loc_conf = null,
};

export const ngx_http_waf_commands = [_]ngx_command_t{
    ngx_command_t{
        .name = ngx_string("waf"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_mode"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_mode,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_sqli"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_sqli,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_xss"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_xss,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_check_body"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_check_body,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_rules_file"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_rules_file,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_ban_threshold"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_ban_threshold,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_ban_window"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_ban_window,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_ban_duration"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_ban_duration,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_score_threshold"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_score_threshold,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    ngx_command_t{
        .name = ngx_string("waf_score_decay_window"),
        .type = conf.NGX_HTTP_LOC_CONF | conf.NGX_CONF_TAKE1,
        .set = ngx_conf_set_waf_score_decay_window,
        .conf = conf.NGX_HTTP_LOC_CONF_OFFSET,
        .offset = 0,
        .post = null,
    },
    conf.ngx_null_command,
};

export var ngx_http_waf_module = ngx.module.make_module(
    @constCast(&ngx_http_waf_commands),
    @constCast(&ngx_http_waf_module_ctx),
);

export const ngx_http_waf_filter_commands = [_]ngx_command_t{conf.ngx_null_command};

export var ngx_http_waf_filter_module = ngx.module.make_module(
    @constCast(&ngx_http_waf_filter_commands),
    @constCast(&ngx_http_waf_filter_module_ctx),
);

// Unit tests
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "waf module" {}

test "urlDecode - basic decoding" {
    var output: [256]u8 = undefined;

    // Test %27 -> '
    const len1 = urlDecode("%27", &output);
    try expectEqual(len1, 1);
    try expectEqual(output[0], '\'');

    // Test %20 -> space
    const len2 = urlDecode("hello%20world", &output);
    try expectEqual(len2, 11);
    try expect(std.mem.eql(u8, output[0..len2], "hello world"));

    // Test + -> space
    const len3 = urlDecode("hello+world", &output);
    try expectEqual(len3, 11);
    try expect(std.mem.eql(u8, output[0..len3], "hello world"));

    // Test complex SQL injection encoded
    const len4 = urlDecode("%27%20OR%20%271%27=%271", &output);
    try expect(std.mem.eql(u8, output[0..len4], "' OR '1'='1"));
}

test "urlDecode - hex characters" {
    var output: [256]u8 = undefined;

    // Test uppercase hex
    const len1 = urlDecode("%2F", &output);
    try expectEqual(len1, 1);
    try expectEqual(output[0], '/');

    // Test lowercase hex
    const len2 = urlDecode("%2f", &output);
    try expectEqual(len2, 1);
    try expectEqual(output[0], '/');
}

test "toLowerSlice - converts to lowercase" {
    var test_buf = [_]u8{ 'H', 'E', 'L', 'L', 'O' };
    toLowerSlice(&test_buf);
    try expect(std.mem.eql(u8, &test_buf, "hello"));

    var test_buf2 = [_]u8{ 'H', 'e', 'L', 'l', 'O' };
    toLowerSlice(&test_buf2);
    try expect(std.mem.eql(u8, &test_buf2, "hello"));
}

test "checkSqli - detects SQL injection patterns" {
    // Test union-based
    try expect(checkSqli("union select * from users") != null);

    // Test comment-based
    try expect(checkSqli("admin'--") != null);

    // Test boolean-based
    try expect(checkSqli("' or 1=1") != null);
    try expect(checkSqli("' or '1'='1") != null);

    // Test clean input
    try expect(checkSqli("hello world") == null);
    try expect(checkSqli("john.doe@example.com") == null);
}

test "checkXss - detects XSS patterns" {
    // Test script tag
    try expect(checkXss("<script>alert(1)</script>") != null);

    // Test event handler
    try expect(checkXss("<img src=x onerror=alert(1)>") != null);

    // Test javascript protocol
    try expect(checkXss("javascript:alert(1)") != null);

    // Test document.cookie
    try expect(checkXss("document.cookie") != null);

    // Test clean input
    try expect(checkXss("hello world") == null);
    try expect(checkXss("normal text here") == null);
}

test "checkSqli - false positives avoided" {
    // Common legitimate inputs that shouldn't trigger
    try expect(checkSqli("john's pizza") == null); // possessive
    try expect(checkSqli("user@example.com") == null);
    try expect(checkSqli("product-name-123") == null);
}

test "checkXss - false positives avoided" {
    // Common legitimate inputs that shouldn't trigger
    try expect(checkXss("hello world") == null);
    try expect(checkXss("price: $100") == null);
    try expect(checkXss("2 < 3 and 5 > 4") == null);
}

test "applyOffenseToEntry escalates repeat offender bans" {
    var lccf = std.mem.zeroes(waf_loc_conf);
    lccf.ban_threshold = 2;
    lccf.ban_window = 60;
    lccf.ban_duration = 2;

    var entry = std.mem.zeroes(waf_ban_entry);

    applyOffenseToEntry(&entry, 100, &lccf, 1);
    try expectEqual(@as(u16, 1), entry.count);
    try expectEqual(@as(u16, 0), entry.strikes);
    try expectEqual(@as(ngx_uint_t, 0), entry.ban_until);

    applyOffenseToEntry(&entry, 101, &lccf, 1);
    try expectEqual(@as(u16, 0), entry.count);
    try expectEqual(@as(u16, 1), entry.strikes);
    try expectEqual(@as(ngx_uint_t, 103), entry.ban_until);

    decayBanEntry(&entry, 104, &lccf);
    try expectEqual(@as(ngx_uint_t, 0), entry.ban_until);
    try expectEqual(@as(u16, 1), entry.strikes);

    applyOffenseToEntry(&entry, 105, &lccf, 1);
    applyOffenseToEntry(&entry, 106, &lccf, 1);
    try expectEqual(@as(u16, 2), entry.strikes);
    try expectEqual(@as(ngx_uint_t, 110), entry.ban_until);
}

test "applyOffenseToEntry bans on score threshold" {
    var lccf = std.mem.zeroes(waf_loc_conf);
    lccf.ban_threshold = 0;
    lccf.ban_window = 60;
    lccf.ban_duration = 3;
    lccf.score_threshold = 2;
    lccf.score_decay_window = 60;

    var entry = std.mem.zeroes(waf_ban_entry);

    applyOffenseToEntry(&entry, 100, &lccf, 1);
    try expectEqual(@as(u16, 1), entry.score);
    try expectEqual(@as(u16, 0), entry.strikes);
    try expectEqual(@as(ngx_uint_t, 0), entry.ban_until);

    applyOffenseToEntry(&entry, 101, &lccf, 1);
    try expectEqual(@as(u16, 0), entry.score);
    try expectEqual(@as(u16, 1), entry.strikes);
    try expectEqual(@as(ngx_uint_t, 104), entry.ban_until);
}

test "applyOffenseToEntry honors weighted score increments" {
    var lccf = std.mem.zeroes(waf_loc_conf);
    lccf.ban_threshold = 0;
    lccf.ban_window = 60;
    lccf.ban_duration = 3;
    lccf.score_threshold = 3;
    lccf.score_decay_window = 60;

    var entry = std.mem.zeroes(waf_ban_entry);

    applyOffenseToEntry(&entry, 100, &lccf, 2);
    try expectEqual(@as(u16, 2), entry.score);
    try expectEqual(@as(ngx_uint_t, 0), entry.ban_until);

    applyOffenseToEntry(&entry, 101, &lccf, 2);

    try expectEqual(@as(u16, 0), entry.score);
    try expectEqual(@as(u16, 1), entry.strikes);
    try expectEqual(@as(ngx_uint_t, 104), entry.ban_until);
}

test "decayBanEntry decays accumulated score" {
    var lccf = std.mem.zeroes(waf_loc_conf);
    lccf.ban_window = 60;
    lccf.score_decay_window = 10;

    var entry = std.mem.zeroes(waf_ban_entry);
    entry.score = 3;
    entry.last_seen = 100;

    decayBanEntry(&entry, 115, &lccf);
    try expectEqual(@as(u16, 2), entry.score);

    decayBanEntry(&entry, 140, &lccf);
    try expectEqual(@as(u16, 0), entry.score);
}
