const std = @import("std");
const ngx = @import("ngx.zig");
const cjson = @import("cjson.zig");
const core = @import("ngx_core.zig");
const string = @import("ngx_string.zig");
const expectEqual = std.testing.expectEqual;

const Pair = core.Pair;
const ngx_uint_t = core.ngx_uint_t;
const ngx_str_t = string.ngx_str_t;
const ngx_string = string.ngx_string;

pub const cJSON = cjson.cJSON;
const Allocator = cjson.Allocator;
const cJSON_Parse = cjson.cJSON_Parse;
const cJSON_ParseWithLength = cjson.cJSON_ParseWithLength;
const cJSON_ParseWithOpts = cjson.cJSON_ParseWithOpts;
const cJSON_ParseWithLengthOpts = cjson.cJSON_ParseWithLengthOpts;
const cJSON_Print = cjson.cJSON_Print;
const cJSON_PrintUnformatted = cjson.cJSON_PrintUnformatted;
const cJSON_PrintBuffered = cjson.cJSON_PrintBuffered;
const cJSON_PrintPreallocated = cjson.cJSON_PrintPreallocated;
const cJSON_Delete = cjson.cJSON_Delete;
pub const cJSON_GetArraySize = cjson.cJSON_GetArraySize;
pub const cJSON_GetArrayItem = cjson.cJSON_GetArrayItem;
pub const cJSON_GetObjectItem = cjson.cJSON_GetObjectItem;
pub const cJSON_GetObjectItemCaseSensit = cjson.cJSON_GetObjectItemCaseSensit;
pub const cJSON_HasObjectItem = cjson.cJSON_HasObjectItem;
pub const cJSON_GetErrorPtr = cjson.cJSON_GetErrorPtr;
pub const cJSON_GetStringValue = cjson.cJSON_GetStringValue;
pub const cJSON_GetNumberValue = cjson.cJSON_GetNumberValue;
pub const cJSON_IsInvalid = cjson.cJSON_IsInvalid;
pub const cJSON_IsFalse = cjson.cJSON_IsFalse;
pub const cJSON_IsTrue = cjson.cJSON_IsTrue;
pub const cJSON_IsBool = cjson.cJSON_IsBool;
pub const cJSON_IsNull = cjson.cJSON_IsNull;
pub const cJSON_IsNumber = cjson.cJSON_IsNumber;
pub const cJSON_IsString = cjson.cJSON_IsString;
pub const cJSON_IsArray = cjson.cJSON_IsArray;
pub const cJSON_IsObject = cjson.cJSON_IsObject;
pub const cJSON_IsRaw = cjson.cJSON_IsRaw;
pub const cJSON_CreateNull = cjson.cJSON_CreateNull;
pub const cJSON_CreateTrue = cjson.cJSON_CreateTrue;
pub const cJSON_CreateFalse = cjson.cJSON_CreateFalse;
pub const cJSON_CreateBool = cjson.cJSON_CreateBool;
pub const cJSON_CreateNumber = cjson.cJSON_CreateNumber;
pub const cJSON_CreateString = cjson.cJSON_CreateString;
pub const cJSON_CreateRaw = cjson.cJSON_CreateRaw;
pub const cJSON_CreateArray = cjson.cJSON_CreateArray;
pub const cJSON_CreateObject = cjson.cJSON_CreateObject;
pub const cJSON_CreateStringReference = cjson.cJSON_CreateStringReference;
pub const cJSON_CreateObjectReference = cjson.cJSON_CreateObjectReference;
pub const cJSON_CreateArrayReference = cjson.cJSON_CreateArrayReference;
pub const cJSON_CreateIntArray = cjson.cJSON_CreateIntArray;
pub const cJSON_CreateFloatArray = cjson.cJSON_CreateFloatArray;
pub const cJSON_CreateDoubleArray = cjson.cJSON_CreateDoubleArray;
pub const cJSON_CreateStringArray = cjson.cJSON_CreateStringArray;
pub const cJSON_AddItemToArray = cjson.cJSON_AddItemToArray;
pub const cJSON_AddItemToObject = cjson.cJSON_AddItemToObject;
pub const cJSON_AddItemToObjectCS = cjson.cJSON_AddItemToObjectCS;
pub const cJSON_AddItemReferenceToArray = cjson.cJSON_AddItemReferenceToArray;
pub const cJSON_AddItemReferenceToObjec = cjson.cJSON_AddItemReferenceToObjec;
pub const cJSON_DetachItemViaPointer = cjson.cJSON_DetachItemViaPointer;
pub const cJSON_DetachItemFromArray = cjson.cJSON_DetachItemFromArray;
pub const cJSON_DeleteItemFromArray = cjson.cJSON_DeleteItemFromArray;
pub const cJSON_DetachItemFromObject = cjson.cJSON_DetachItemFromObject;
pub const cJSON_DetachItemFromObjectCas = cjson.cJSON_DetachItemFromObjectCas;
pub const cJSON_DeleteItemFromObject = cjson.cJSON_DeleteItemFromObject;
pub const cJSON_DeleteItemFromObjectCas = cjson.cJSON_DeleteItemFromObjectCas;
pub const cJSON_InsertItemInArray = cjson.cJSON_InsertItemInArray;
pub const cJSON_ReplaceItemViaPointer = cjson.cJSON_ReplaceItemViaPointer;
pub const cJSON_ReplaceItemInArray = cjson.cJSON_ReplaceItemInArray;
pub const cJSON_ReplaceItemInObject = cjson.cJSON_ReplaceItemInObject;
pub const cJSON_ReplaceItemInObjectCase = cjson.cJSON_ReplaceItemInObjectCase;
pub const cJSON_Duplicate = cjson.cJSON_Duplicate;
pub const cJSON_Compare = cjson.cJSON_Compare;
pub const cJSON_Minify = cjson.cJSON_Minify;
pub const cJSON_AddNullToObject = cjson.cJSON_AddNullToObject;
pub const cJSON_AddTrueToObject = cjson.cJSON_AddTrueToObject;
pub const cJSON_AddFalseToObject = cjson.cJSON_AddFalseToObject;
pub const cJSON_AddBoolToObject = cjson.cJSON_AddBoolToObject;
pub const cJSON_AddNumberToObject = cjson.cJSON_AddNumberToObject;
pub const cJSON_AddStringToObject = cjson.cJSON_AddStringToObject;
pub const cJSON_AddRawToObject = cjson.cJSON_AddRawToObject;
pub const cJSON_AddObjectToObject = cjson.cJSON_AddObjectToObject;
pub const cJSON_AddArrayToObject = cjson.cJSON_AddArrayToObject;
const cJSON_SetNumberHelper = cjson.cJSON_SetNumberHelper;
const cJSON_SetValuestring = cjson.cJSON_SetValuestring;
const cJSON_malloc = cjson.cJSON_malloc;
const cJSON_free = cjson.cJSON_free;

fn cjson_palloc(size: usize, ctx: ?*anyopaque) callconv(.c) ?*anyopaque {
    if (core.castPtr(core.ngx_pool_t, ctx)) |p| {
        return core.ngx_pcalloc(p, size);
    }
    return null;
}

fn cjson_pfree(p: ?*anyopaque) callconv(.c) void {
    _ = p;
}

pub const CJSON = extern struct {
    const Self = @This();
    const CJSON_BUFFER_LENTH = 512;
    const CJSON_DEPTH = 256;

    pub fn intValue(j: [*c]cJSON) ?i64 {
        if (cJSON_IsNumber(j) == 1) {
            return @as(i64, @intFromFloat(cJSON_GetNumberValue(j)));
        }
        return null;
    }

    pub fn floatValue(j: [*c]cJSON) ?f64 {
        if (cJSON_IsNumber(j) == 1) {
            return cJSON_GetNumberValue(j);
        }
        return null;
    }

    pub fn boolValue(j: [*c]cJSON) ?bool {
        if (cJSON_IsBool(j) == 1) {
            return cJSON_IsTrue(j) == 1;
        }
        return null;
    }

    pub fn stringValue(j: [*c]cJSON) ?ngx_str_t {
        if (cJSON_IsString(j) == 1) {
            return ngx_str_t{ .data = j.*.valuestring, .len = string.strlen(j.*.valuestring) };
        }
        return null;
    }

    pub fn objValue(j: [*c]cJSON) ?[*c]cJSON {
        if (cJSON_IsObject(j) == 1) {
            return j;
        }
        return null;
    }

    pub fn arrValue(j: [*c]cJSON) ?[*c]cJSON {
        if (cJSON_IsArray(j) == 1) {
            return j;
        }
        return null;
    }

    // p[] must be long/deep enough and p[0] == j.*
    pub fn iterate(j: [*c][*c]cJSON, p: [*c][*c]cJSON, i: *ngx_uint_t) ?[*c]cJSON {
        outer: while (j.* == core.nullptr(cJSON)) {
            while (i.* > 0) {
                if (p[i.*].*.next != core.nullptr(cJSON)) {
                    j.* = p[i.*].*.next;
                    i.* -= 1;
                    break :outer;
                }
                i.* -= 1;
            }
            return null;
        }
        if (cJSON_IsObject(j.*) == 1 or cJSON_IsArray(j.*) == 1) {
            i.* += 1;
            p[i.*] = j.*;
            defer j.* = j.*.*.child;
            return j.*;
        }
        defer j.* = j.*.*.next;
        return j.*;
    }

    pub fn query(j: [*c]cJSON, path: []const u8) ?[*c]cJSON {
        if (j == core.nullptr(cJSON)) {
            return null;
        }
        if (path.len == 0) {
            return j;
        }
        if (path[0] == '$') {
            return query(j, path[1..]);
        }
        if (path[0] == '.') {
            var i: usize = 1;
            var d: ?usize = 0;
            while (i < path.len and path[i] != '.') : (i += 1) {
                if (d != null and path[i] >= '0' and path[i] <= '9') {
                    d = d.? * 10 + path[i] - '0';
                } else {
                    d = null;
                }
            }
            if (i > 1) {
                if (d == null) { // object
                    const key_slice = path[1..i];
                    if (key_slice.len >= 256) return null;
                    var key: [256]u8 = std.mem.zeroes([256]u8);
                    @memcpy(key[0..key_slice.len], key_slice);
                    return query(cJSON_GetObjectItem(j, &key), path[i..]);
                } else { // array
                    return query(cJSON_GetArrayItem(j, @intCast(d.?)), path[i..]);
                }
            }
        }
        return null;
    }

    pub const Iterator = struct {
        const Iter = @This();
        v: [*c]cJSON,

        pub fn init(j: [*c]cJSON) Iter {
            if (cJSON_IsObject(j) == 1 or cJSON_IsArray(j) == 1) {
                return Iter{ .v = j.*.child };
            }
            return Iter{ .v = j };
        }

        pub fn next(self: *Iter) ?[*c]cJSON {
            if (self.v == core.nullptr(cJSON)) {
                return null;
            }
            defer self.v = self.v.*.next;
            return self.v;
        }
    };

    pub const RecursiveIterator = struct {
        const Iter = @This();
        v: [*c]cJSON,
        p: [CJSON_DEPTH][*c]cJSON = undefined,
        i: ngx_uint_t = 0,

        pub fn init(j: [*c]cJSON) Iter {
            var it = Iter{ .v = j };
            it.p[0] = it.v;
            return it;
        }

        pub fn next(self: *Iter) ?[*c]cJSON {
            return iterate(&self.v, &self.p, &self.i);
        }

        pub fn nextPair(self: *Iter) ?Pair([*c]cJSON, [*c]cJSON) {
            if (next(self)) |n| {
                if (cJSON_IsObject(n) == 1 or cJSON_IsArray(n) == 1) {
                    const p = if (self.i > 0) self.p[self.i - 1] else self.p[0];
                    return Pair([*c]cJSON, [*c]cJSON){ .t = n, .u = p };
                }
                return Pair([*c]cJSON, [*c]cJSON){ .t = n, .u = self.p[self.i] };
            }
            return null;
        }
    };

    alloc: Allocator,

    pub fn init(pool: [*c]core.ngx_pool_t) Self {
        return Self{
            .alloc = Allocator{
                .ctx = pool,
                .allocate = cjson_palloc,
                .deallocate = cjson_pfree,
                .reallocate = null,
            },
        };
    }

    pub fn decode(self: *Self, str: ngx_str_t) ![*c]cJSON {
        const json = cJSON_ParseWithLength(str.data, str.len, &self.alloc);
        return if (json == core.nullptr(cJSON)) core.NError.JSON_ERROR else json;
    }

    pub fn encode(self: *Self, j: [*c]cJSON) !ngx_str_t {
        const MAX_ENCODE_SIZE: usize = 16 * 1024 * 1024;
        if (core.castPtr(core.ngx_pool_t, self.alloc.ctx)) |pool| {
            var size: usize = CJSON_BUFFER_LENTH;
            var len: usize = 0;
            while (size <= MAX_ENCODE_SIZE) {
                const raw = core.ngx_pnalloc(pool, size) orelse break;
                const p = core.castPtr(u8, raw) orelse break;
                const b = cJSON_PrintPreallocated(j, p, @as(c_int, @intCast(size)), 0, &len);
                if (b == 1) {
                    return ngx_str_t{ .len = len, .data = p };
                }
                size *= 2;
            }
        }
        return core.NError.OOM;
    }

    pub fn free(self: *Self, p: ?*anyopaque) void {
        cJSON_free(p, &self.alloc);
    }
};

const ngx_log_init = ngx.ngx_log_init;
const ngx_create_pool = ngx.ngx_create_pool;
const ngx_destroy_pool = ngx.ngx_destroy_pool;
test "cjson" {
    try expectEqual(@sizeOf(cJSON), 64);
    const log = ngx_log_init(core.c_str(""), core.c_str(""));
    const pool = ngx_create_pool(1024, log);
    defer ngx_destroy_pool(pool);

    const json =
        \\{
        \\"a": {"x": 100},
        \\"b": [1,2,3],
        \\"c": {"x": 1, "y": 42}
        \\}
    ;
    var cj = CJSON.init(pool);
    const parsed = try cj.decode(ngx_string(json));
    try expectEqual(cJSON_IsObject(parsed), 1);
    try expectEqual(cJSON_GetArraySize(cJSON_GetObjectItem(parsed, "b")), 3);

    var rt = CJSON.RecursiveIterator.init(parsed);
    var sum: i32 = 0;
    var cstr = [4]u8{ 'c', 0, '5', 0 };
    while (rt.next()) |j| {
        if (CJSON.query(j, "$.x")) |_| {
            if (cJSON_AddStringToObject(j, &cstr, @as([*c]u8, @ptrCast(&cstr)) + 2, &cj.alloc) == core.nullptr(cJSON)) {
                unreachable;
            }
        }
        sum += 1;
    }
    try expectEqual(sum, 12);

    try expectEqual(CJSON.query(parsed, "$.5"), null);
    try expectEqual(CJSON.query(parsed, "$.5.z"), null);
    try expectEqual(CJSON.query(parsed, "$.c.z"), null);
    try expectEqual(@as(i32, @intFromFloat(cJSON_GetNumberValue(CJSON.query(parsed, "$.b.2").?))), 3);
    try expectEqual(@as(i32, @intFromFloat(cJSON_GetNumberValue(CJSON.query(parsed, "$.c.y").?))), 42);

    sum = 0;
    var it = CJSON.Iterator.init(CJSON.query(parsed, "$.b").?);
    while (it.next()) |j| {
        sum += @intFromFloat(cJSON_GetNumberValue(j));
    }
    try expectEqual(sum, 6);

    const j = try cj.encode(parsed);
    try expectEqual(j.len, 62);
    // std.debug.print("{s}", .{core.slicify(u8, j.data, j.len)});

    var long_key_path: [300]u8 = undefined;
    long_key_path[0] = '$';
    long_key_path[1] = '.';
    @memset(long_key_path[2..], 'k');
    try expectEqual(CJSON.query(parsed, long_key_path[0..]), null);

    cj.free(parsed);
}
