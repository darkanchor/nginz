const std = @import("std");
const ngx = @import("ngx.zig");
const core = @import("ngx_core.zig");
const http = @import("ngx_http.zig");
const module = @import("ngx_module.zig");
const rbtree = @import("ngx_rbtree.zig");
const ngx_queue = @import("ngx_queue.zig");
const expectEqual = std.testing.expectEqual;

const ngx_int_t = core.ngx_int_t;
const ngx_msec_t = core.ngx_msec_t;
const ngx_http_request_t = http.ngx_http_request_t;

extern var ngx_event_timer_rbtree: rbtree.ngx_rbtree_t;
extern var ngx_current_msec: ngx_msec_t;
extern var ngx_posted_events: ngx_queue.ngx_queue_t;

pub const ngx_event_t = core.ngx_event_t;
pub const ngx_event_handler_pt = ngx.ngx_event_handler_pt;

pub inline fn ngx_event_del_timer(ev: [*c]ngx_event_t) void {
    rbtree.ngx_rbtree_delete(&ngx_event_timer_rbtree, &ev.*.timer);
    ev.*.timer.left = core.nullptr(rbtree.ngx_rbtree_node_t);
    ev.*.timer.right = core.nullptr(rbtree.ngx_rbtree_node_t);
    ev.*.timer.parent = core.nullptr(rbtree.ngx_rbtree_node_t);
    ev.*.flags.timer_set = false;
}

const NGX_TIMER_LAZY_DELAY = ngx.NGX_TIMER_LAZY_DELAY;
pub inline fn ngx_event_add_timer(ev: [*c]ngx_event_t, timer: ngx_msec_t) void {
    const key: ngx_msec_t = ngx_current_msec + timer;
    if (ev.*.flags.timer_set) {
        if (@abs(key - ev.*.timer.key) < NGX_TIMER_LAZY_DELAY) {
            return;
        }
        ngx_event_del_timer(ev);
    }
    ev.*.timer.key = key;
    ev.*.flags.timer_set = true;
    rbtree.ngx_rbtree_insert(&ngx_event_timer_rbtree, &ev.*.timer);
}

/// Post an event to be processed at the end of the current event loop iteration.
/// Implements the ngx_post_event(ev, &ngx_posted_events) macro for deferring
/// event handlers out of deeply nested call stacks.
pub inline fn ngz_post_event(ev: [*c]ngx_event_t) void {
    if (!ev.*.flags.posted) {
        ev.*.flags.posted = true;
        ngx_queue.ngx_queue_insert_tail(&ngx_posted_events, &ev.*.queue);
    }
}

pub const NTimer = struct {
    const TimerUnit = extern struct {
        request: [*c]ngx_http_request_t,
        handler: http.ngx_http_handler_pt,
        timer: ngx_event_t,
    };

    fn timer_handler(ev: [*c]ngx_event_t) callconv(.c) void {
        if (core.castPtr(TimerUnit, ev.*.data)) |self| {
            const r = self.*.request;
            if (r.*.connection.*.flags.destroyed) {
                return;
            }
            if (r.*.connection.*.flags.@"error") {
                http.ngx_http_finalize_request(r, core.NGX_ERROR);
                return;
            }
            if (!self.*.timer.flags.timedout) {
                return;
            }
            self.*.timer.flags.timedout = false;
            if (self.*.timer.flags.timer_set) {
                ngx_event_del_timer(&self.*.timer);
            }

            if (core.castPtr(http.ngx_http_log_ctx_t, r.*.connection.*.log.*.data)) |ctx| {
                ctx.*.current_request = r;
            }
            // NGX_DONE already did r.*.main.*.flags0.count -= 1;
            if (self.*.handler) |handle| {
                const rc = handle(r);
                http.ngx_http_finalize_request(r, rc);
                if (r.*.main.*.posted_requests != core.nullptr(http.ngx_http_posted_request_t)) {
                    http.ngx_http_run_posted_requests(r.*.connection);
                }
            }
        }
    }

    fn timer_cleanup(data: ?*anyopaque) callconv(.c) void {
        if (core.castPtr(TimerUnit, data)) |self| {
            if (self.*.timer.flags.timer_set) {
                ngx_event_del_timer(&self.*.timer);
            }
        }
    }

    pub fn activate(r: [*c]ngx_http_request_t, handler: http.ngx_http_handler_pt, d: ngx_msec_t) !void {
        if (core.ngz_pcalloc_c(TimerUnit, r.*.pool)) |self| {
            self.*.timer.data = self;
            self.*.timer.handler = timer_handler;
            self.*.timer.log = r.*.connection.*.log;
            self.*.handler = handler;
            self.*.request = r;
            self.*.request.*.main.*.flags0.count += 1;
            ngx_event_add_timer(&self.*.timer, d);

            if (core.nonNullPtr(
                http.ngx_http_cleanup_t,
                http.ngx_http_cleanup_add(r, 0),
            )) |cln| {
                cln.*.data = self;
                cln.*.handler = timer_cleanup;
                return;
            }
        }
        return core.NError.TIMER_ERROR;
    }
};
