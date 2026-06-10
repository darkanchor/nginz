const std = @import("std");
const ngx = @import("ngx.zig");
const core = @import("ngx_core.zig");
const expectEqual = std.testing.expectEqual;

pub const ngx_queue_t = ngx.ngx_queue_t;
const ngx_uint_t = core.ngx_uint_t;

pub inline fn ngx_queue_init(q: [*c]ngx_queue_t) void {
    q.*.prev = q;
    q.*.next = q;
}

pub inline fn ngx_queue_empty(q: [*c]ngx_queue_t) bool {
    return q == q.*.prev;
}

pub inline fn ngx_queue_head(h: [*c]ngx_queue_t) [*c]ngx_queue_t {
    return h.*.next;
}

pub inline fn ngx_queue_tail(h: [*c]ngx_queue_t) [*c]ngx_queue_t {
    return h.*.prev;
}

pub inline fn ngx_queue_next(q: [*c]ngx_queue_t) [*c]ngx_queue_t {
    return q.*.next;
}

pub inline fn ngx_queue_prev(q: [*c]ngx_queue_t) [*c]ngx_queue_t {
    return q.*.prev;
}

pub inline fn ngx_queue_remove(x: [*c]ngx_queue_t) void {
    x.*.next.*.prev = x.*.prev;
    x.*.prev.*.next = x.*.next;
    x.*.prev = x;
    x.*.next = x;
}

pub inline fn ngx_queue_sentinel(q: [*c]ngx_queue_t) [*c]ngx_queue_t {
    return q;
}

pub inline fn ngx_queue_insert_head(h: [*c]ngx_queue_t, x: [*c]ngx_queue_t) void {
    x.*.next = h.*.next;
    x.*.next.*.prev = x;
    x.*.prev = h;
    h.*.next = x;
}

pub inline fn ngx_queue_insert_before(h: [*c]ngx_queue_t, x: [*c]ngx_queue_t) void {
    ngx_queue_insert_head(h, x);
}

pub inline fn ngx_queue_insert_tail(h: [*c]ngx_queue_t, x: [*c]ngx_queue_t) void {
    x.*.prev = h.*.prev;
    x.*.prev.*.next = x;
    x.*.next = h;
    h.*.prev = x;
}

pub inline fn ngx_queue_insert_after(h: [*c]ngx_queue_t, x: [*c]ngx_queue_t) void {
    ngx_queue_insert_tail(h, x);
}

pub inline fn ngx_queue_split(h: [*c]ngx_queue_t, q: [*c]ngx_queue_t, n: [*c]ngx_queue_t) void {
    n.*.prev = h.*.prev;
    n.*.prev.*.next = n;
    n.*.next = q;
    h.*.prev = q.*.prev;
    h.*.prev.*.next = h;
    q.*.prev = n;
}

pub inline fn ngx_queue_add(h: [*c]ngx_queue_t, n: [*c]ngx_queue_t) void {
    h.*.prev.*.next = n.*.next;
    n.*.next.*.prev = h.*.prev;
    h.*.prev = n.*.prev;
    h.*.prev.*.next = h;
}

pub inline fn ngz_queue_data(comptime T: type, comptime field: []const u8, q: [*c]ngx_queue_t) [*c]T {
    return @as(
        [*c]T,
        @alignCast(@ptrCast(@as([*c]u8, @alignCast(@ptrCast(q))) - @offsetOf(T, field))),
    );
}

// ngx_queue_init(s)
// n = ngx_queue_next(s)
pub fn ngz_queue_next(comptime T: type, comptime field: []const u8, s: [*c]ngx_queue_t, n: *[*c]ngx_queue_t) ?[*c]T {
    if (n.* != s) {
        defer n.* = ngx_queue_next(n.*);
        return ngz_queue_data(T, field, n.*);
    }
    return null;
}

pub fn NQueue(comptime T: type, comptime field: []const u8) type {
    const OFFSET = @offsetOf(T, field);

    const Iterator = struct {
        const Self = @This();

        q: [*c]ngx_queue_t,
        n: [*c]ngx_queue_t,

        pub fn next(self: *Self) ?[*c]T {
            if (self.n == self.q) {
                return null;
            }
            defer self.n = ngx_queue_next(self.n);
            return @as(
                [*c]T,
                @alignCast(@ptrCast(@as([*c]u8, @alignCast(@ptrCast(self.n))) - OFFSET)),
            );
        }
    };

    const ReverseIterator = struct {
        const Self = @This();

        q: [*c]ngx_queue_t,
        n: [*c]ngx_queue_t,

        pub fn next(self: *Self) ?[*c]T {
            if (self.n == self.q) {
                return null;
            }
            defer self.n = ngx_queue_prev(self.n);
            return @as(
                [*c]T,
                @alignCast(@ptrCast(@as([*c]u8, @alignCast(@ptrCast(self.n))) - OFFSET)),
            );
        }
    };

    return extern struct {
        const Self = @This();
        sentinel: [*c]ngx_queue_t,
        len: ngx_uint_t = 0,

        pub inline fn queue(pt: [*c]T) [*c]ngx_queue_t {
            return @as(
                [*c]ngx_queue_t,
                @alignCast(@ptrCast(@as([*c]u8, @alignCast(@ptrCast(pt))) + OFFSET)),
            );
        }

        pub inline fn data(q: [*c]ngx_queue_t) [*c]T {
            return @as(
                [*c]T,
                @alignCast(@ptrCast(@as([*c]u8, @alignCast(@ptrCast(q))) - OFFSET)),
            );
        }

        pub fn init(s: [*c]ngx_queue_t) Self {
            ngx_queue_init(s);
            return Self{ .sentinel = s };
        }

        pub fn iterator(self: *Self) Iterator {
            return Iterator{ .q = self.sentinel, .n = ngx_queue_next(self.sentinel) };
        }

        pub fn reverse_iterator(self: *Self) ReverseIterator {
            return ReverseIterator{ .q = self.sentinel, .n = ngx_queue_prev(self.sentinel) };
        }

        pub fn size(self: *Self) ngx_uint_t {
            return self.len;
        }

        pub fn at(self: *Self, i: ngx_uint_t) ?[*c]T {
            if (i < self.len) {
                var n: [*c]ngx_queue_t = ngx_queue_head(self.sentinel);
                for (0..i) |_| {
                    n = n.*.next;
                }
                return data(n);
            }
            return null;
        }

        pub fn head(self: *Self) [*c]T {
            return data(ngx_queue_head(self.sentinel));
        }

        pub fn tail(self: *Self) [*c]T {
            return data(ngx_queue_tail(self.sentinel));
        }

        pub fn insert_before(self: *Self, q0: [*c]ngx_queue_t, pt1: [*c]T) void {
            defer self.len += 1;
            const q1 = queue(pt1);
            ngx_queue_insert_before(q0, q1);
        }

        pub fn insert_after(self: *Self, q0: [*c]ngx_queue_t, pt1: [*c]T) void {
            defer self.len += 1;
            const q1 = queue(pt1);
            ngx_queue_insert_after(q0, q1);
        }

        pub fn insert_head(self: *Self, pt: [*c]T) void {
            insert_before(self, self.sentinel, pt);
        }

        pub fn insert_tail(self: *Self, pt: [*c]T) void {
            insert_after(self, self.sentinel, pt);
        }

        pub fn remove(self: *Self, pt: [*c]T) void {
            if (!empty(self)) {
                defer self.len -= 1;
                const q = queue(pt);
                ngx_queue_remove(q);
            }
        }

        pub fn empty(self: *Self) bool {
            return ngx_queue_empty(self.sentinel);
        }
    };
}

test "queue" {
    try expectEqual(@sizeOf(ngx_queue_t), 16);
    const QT = extern struct {
        n: ngx_uint_t,
        q: ngx_queue_t = undefined,
    };

    var qt: ngx_queue_t = undefined;
    var q0 = NQueue(QT, "q").init(&qt);
    try expectEqual(q0.size(), 0);

    var q4 = [_]QT{
        QT{ .n = 0 },
        QT{ .n = 1 },
        QT{ .n = 2 },
        QT{ .n = 3 },
        QT{ .n = 4 },
    };
    for (&q4) |*qx| {
        // ngx_queue_init(&qx.q);
        q0.insert_tail(qx);
    }

    try expectEqual(q0.at(3).?.*.n, 3);
    var it = q0.iterator();
    var total: ngx_uint_t = 0;
    while (it.next()) |_| {
        total += 1;
    }
    try expectEqual(q0.size(), total);
    try expectEqual(q0.at(total), null);

    var rit = q0.reverse_iterator();
    var rev_count: ngx_uint_t = 0;
    var prev_n: ngx_uint_t = 5;
    while (rit.next()) |elem| {
        try std.testing.expect(elem.*.n < prev_n);
        prev_n = elem.*.n;
        rev_count += 1;
    }
    try expectEqual(rev_count, 5);
    try expectEqual(prev_n, 0);
}
