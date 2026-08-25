const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const tui = @import("tui.zig");
const activity = @import("activity.zig");
const Tool = @import("../core/tool.zig");
const chat = @import("chat.zig");
const ansi = @import("../core/ansi.zig");
const runs_mod = @import("runs.zig");
const sink = @import("../core/sink.zig");

const log = std.log.scoped(.live);

comptime {
    if (sink.stopping_phrase.len > activity.max_phrase)
        @compileError("stopping_phrase must fit in Act.label_buf");
}

/// Exclusive sinks. JSON never paints; stream is one-shot ask; tui owns layout.
pub const Live = union(enum) {
    json: Json,
    stream: Stream,
    tui: Tty,

    pub const Json = struct {
        stdout: *Io.Writer,
        cancel: *std.atomic.Value(bool),
    };

    pub const Stream = struct {
        stdout: *Io.Writer,
        cancel: *std.atomic.Value(bool),
        allocator: std.mem.Allocator,
        think_view: tui.ThinkView,
        paint: bool,
        think: chat.Think = .{},
    };

    pub const Tty = struct {
        stdout: *Io.Writer,
        stdin: *Io.Reader,
        allocator: std.mem.Allocator,
        layout: *tui.Layout,
        footer: tui.Footer,
        cancel: *std.atomic.Value(bool),
        shown: *tui.Transcript,
        think_view: tui.ThinkView,
        asst_hold: *std.ArrayList(u8),
        scroll: *usize,
        /// Fence and table state, shared with the retained transcript render.
        md: *chat.Markdown,
        /// What the status row says. Owned by the caller so it survives the
        /// whole turn; the tool hooks update it as work changes.
        act: *Act,
        /// Run of consecutive same-tool calls waiting to be committed.
        group: *Run,
        /// Where each committed run landed, so a click can open it later.
        runs: *runs_mod.Store,
        arena: std.mem.Allocator,
        paint_lock: std.atomic.Value(u32) = .init(0),
        last_status_ms: ?i64 = null,
        last_title: [96]u8 = undefined,
        last_title_len: usize = 0,
        spin_stop: std.atomic.Value(bool) = .init(true),
        spin_thread: ?std.Thread = null,
        /// Row and held-back word of the thinking block. Reset when one opens.
        think: chat.Think = .{},
    };

    /// A run of identical tool calls, buffered until it ends.
    ///
    /// Buffered rather than rewritten in place because the transcript is
    /// append-only: once bytes are folded into rows there is nothing to edit.
    /// The live count lives on the activity line meanwhile, so nothing is lost.
    pub const Run = struct {
        name: []const u8 = "",
        details: std.ArrayList([]const u8) = .empty,
        /// The output of each call, parallel to `details`. Kept so an opened
        /// child can show what the call actually returned.
        bodies: std.ArrayList([]const u8) = .empty,
        expanded: bool = false,

        pub fn accepts(self: Run, name: []const u8) bool {
            return self.details.items.len > 0 and std.mem.eql(u8, self.name, name);
        }

        pub fn open(self: *Run, arena: std.mem.Allocator, name: []const u8, detail: []const u8, body: []const u8) void {
            self.name = arena.dupe(u8, name) catch name;
            self.details.clearRetainingCapacity();
            self.bodies.clearRetainingCapacity();
            self.push(arena, detail, body);
        }

        pub fn push(self: *Run, arena: std.mem.Allocator, detail: []const u8, body: []const u8) void {
            // A call with no argument still happened, and a blank tree row is
            // a row nobody can read: name the tool instead of drawing nothing.
            const shown = if (detail.len != 0) detail else self.name;
            const d = arena.dupe(u8, shown) catch |err| blk: {
                log.debug("group dupe: {s}", .{@errorName(err)});
                break :blk shown;
            };
            self.details.append(arena, d) catch |err| {
                log.debug("group append: {s}", .{@errorName(err)});
            };
            const b = arena.dupe(u8, body) catch "";
            self.bodies.append(arena, b) catch |err| {
                log.debug("group body: {s}", .{@errorName(err)});
            };
        }

        pub fn clear(self: *Run) void {
            self.name = "";
            self.details.clearRetainingCapacity();
            self.bodies.clearRetainingCapacity();
        }
    };

    /// Live activity. Copied in because the call's JSON dies with the turn step.
    pub const Act = struct {
        state: activity.State = .{},
        started_ms: i64 = 0,
        buf: [activity.max_phrase * 2]u8 = undefined,
        name_buf: [32]u8 = undefined,
        label_buf: [activity.max_phrase]u8 = undefined,

        pub fn begin(self: *Act) void {
            self.started_ms = wallMs();
            self.state = .{};
        }

        /// Repeats of the same tool collapse into a count rather than flickering.
        pub fn tool(self: *Act, name: []const u8, label: []const u8) void {
            const same = if (self.state.tool_name.len == 0)
                false
            else
                std.mem.eql(u8, self.state.tool_name, name);
            if (same) {
                self.state.count += 1;
            } else {
                self.state.count = 1;
                const name_len = @min(name.len, self.name_buf.len);
                @memcpy(self.name_buf[0..name_len], name[0..name_len]);
                self.state.tool_name = self.name_buf[0..name_len];
            }
            const label_len = @min(label.len, self.label_buf.len);
            @memcpy(self.label_buf[0..label_len], label[0..label_len]);
            self.state.label = self.label_buf[0..label_len];
            self.state.tool = Tool.Name.fromSlice(self.state.tool_name);
            self.state.streaming = false;
        }

        /// Everything the window is holding, cache included: a turn served
        /// from cache reports one input token and a hundred thousand cached
        /// ones, and the window is full either way.
        pub fn usage(self: *Act, input: u32, output: u32, read: u32, write: u32) void {
            self.state.tokens = input +| output +| read +| write;
            self.state.fresh_input = input;
            self.state.cache_read = read;
            self.state.cache_write = write;
        }

        /// Tokens are on screen. Clearing the tool without this flag would
        /// put "Waiting for response" back over the reply.
        pub fn text(self: *Act) void {
            self.state.tool = null;
            self.state.tool_name = "";
            self.state.label = "";
            self.state.count = 1;
            self.state.streaming = true;
        }

        pub fn render(self: *Act, now_ms: i64) []const u8 {
            const elapsed = now_ms - self.started_ms;
            self.state.elapsed_ms = elapsed;
            return activity.line(&self.buf, self.state, activity.frameOf(elapsed));
        }

        pub fn renderNow(self: *Act) []const u8 {
            return self.render(wallMs());
        }
    };

    const Extra = union(enum) {
        none,
        line: []const u8,
    };

    fn writeOut(w: *Io.Writer, chunk: []const u8) void {
        w.writeAll(chunk) catch |err| {
            log.debug("write: {s}", .{@errorName(err)});
        };
        w.flush() catch |err| {
            log.debug("flush: {s}", .{@errorName(err)});
        };
    }

    /// Kernel clock, not `Io.Clock`: that vtable can sit still while the main
    /// thread is blocked in HTTP, which froze the spinner until the first token.
    fn wallMs() i64 {
        const posix = std.posix;
        const id: posix.clockid_t = switch (builtin.os.tag) {
            .macos, .ios, .tvos, .watchos, .visionos => posix.CLOCK.UPTIME_RAW,
            else => posix.CLOCK.MONOTONIC,
        };
        var ts: posix.timespec = undefined;
        switch (posix.errno(posix.system.clock_gettime(id, &ts))) {
            .SUCCESS => return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000),
            else => return 0,
        }
    }

    fn lockPaint(self: *Tty) void {
        while (self.paint_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlockPaint(self: *Tty) void {
        self.paint_lock.store(0, .release);
    }

    fn paintTty(self: *Tty, extra: Extra) void {
        // A stopping spinner must not paint a generating frame over idle.
        if (self.spin_thread != null and self.spin_stop.load(.acquire)) return;
        lockPaint(self);
        defer unlockPaint(self);
        const now = wallMs();
        if (extra == .none and !self.cancel.load(.acquire)) {
            if (self.last_status_ms) |prev| {
                if (now - prev < activity.spin_ms) return;
            }
        }
        self.last_status_ms = now;
        // `extra` is the half-streamed line: shown, but not committed, so the
        // finished line renders exactly once when it lands.
        switch (extra) {
            .none => self.shown.clearTail(),
            .line => |l| self.shown.setTail(l),
        }
        self.shown.resize(self.layout.cols) catch |err| {
            log.debug("transcript resize: {s}", .{@errorName(err)});
        };
        if (self.cancel.load(.acquire)) {
            @memcpy(self.act.label_buf[0..sink.stopping_phrase.len], sink.stopping_phrase);
            self.act.state.label = self.act.label_buf[0..sink.stopping_phrase.len];
            self.act.state.tool_name = "";
            self.act.state.tool = null;
            self.act.state.streaming = false;
        }
        var footer = self.footer;
        footer.status = self.act.render(now);
        // Words typed during the turn go into the steer queue. They are drawn
        // as their own row rather than inside the composer: the composer is
        // where the next prompt is written, and a queued message is a message
        // already committed to this turn.
        const q = sink.peekSteer();
        var rows: [sink.max_queued][]const u8 = undefined;
        var row_bufs: [sink.max_queued][96]u8 = undefined;
        for (q.slice(), 0..) |msg, i| {
            rows[i] = std.fmt.bufPrint(&row_bufs[i], "{s}  #{d} {s}{s}", .{
                ansi.muted,
                i + 1,
                chat.clipCols(msg, if (self.layout.cols > 8) self.layout.cols - 8 else self.layout.cols),
                ansi.reset,
            }) catch msg;
        }
        // Borrowed from this frame, so it is unset before the frame goes: a
        // pinned row outliving its bytes is how the status row drew garbage.
        self.shown.setQueued(rows[0..q.n]);
        defer self.shown.setQueued(&.{});
        footer.queued = q.typing;
        if (q.typing.len != 0) footer.caret = q.typing.len;
        tui.writePane(self.allocator, self.stdout, self.layout.*, footer, self.shown, self.scroll.*) catch |err| {
            log.debug("writePane: {s}", .{@errorName(err)});
            return;
        };
        var head_buf: [activity.max_phrase]u8 = undefined;
        var title_buf: [96]u8 = undefined;
        const title = tui.tabTitleSeq(
            &title_buf,
            activity.frameOf(self.act.state.elapsed_ms),
            activity.headline(&head_buf, self.act.state),
        );
        if (self.last_title_len != title.len or !std.mem.eql(u8, self.last_title[0..self.last_title_len], title)) {
            std.debug.assert(title.len <= self.last_title.len);
            self.last_title_len = title.len;
            @memcpy(self.last_title[0..title.len], title);
            self.stdout.writeAll(title) catch |err| {
                log.debug("tab title: {s}", .{@errorName(err)});
            };
        }
        self.stdout.flush() catch |err| {
            log.debug("flush: {s}", .{@errorName(err)});
        };
    }

    fn previewAsst(self: *Tty) void {
        if (self.asst_hold.items.len == 0) return;
        self.md.cols = self.layout.cols;
        const painted = self.md.peek(self.allocator, self.asst_hold.items) catch {
            paintTty(self, .{ .line = self.asst_hold.items });
            return;
        };
        defer self.allocator.free(painted);
        paintTty(self, .{ .line = painted });
    }

    fn writeShown(self: *Tty, chunk: []const u8) void {
        self.shown.resize(self.layout.cols) catch |err| {
            log.debug("transcript resize: {s}", .{@errorName(err)});
        };
        self.shown.append(chunk) catch |err| {
            log.debug("transcript append: {s}", .{@errorName(err)});
            return;
        };
        paintTty(self, .none);
    }

    fn closeThinkStream(self: *Stream) void {
        const tail = self.think_view.end();
        if (tail.len == 0) return;
        if (chat.flushThink(self.allocator, 80, &self.think)) |held| {
            defer self.allocator.free(held);
            if (held.len != 0) writeOut(self.stdout, held);
        } else |err| {
            log.debug("flush think: {s}", .{@errorName(err)});
        }
        writeOut(self.stdout, tail);
    }

    /// Commits a buffered run to the transcript: one summary row, plus a tree
    /// of the individual calls when the run is expanded.
    fn flushGroup(self: *Tty) void {
        const n = self.group.details.items.len;
        if (n == 0) return;
        defer self.group.clear();
        const off = self.shown.bytes().len;
        const row = chat.formatGroup(self.allocator, self.layout.cols, .{
            .name = self.group.name,
            .last_detail = self.group.details.items[n - 1],
            .count = n,
            .expanded = self.group.expanded,
        }) catch return;
        defer self.allocator.free(row);
        writeShown(self, row);
        if (self.group.expanded and n >= 2) {
            for (self.group.details.items, 0..) |d, i| {
                const child = chat.formatGroupChild(self.allocator, self.layout.cols, self.group.name, d, i + 1 == n, false) catch continue;
                defer self.allocator.free(child);
                writeShown(self, child);
            }
        }
        // The turn arena that holds these details dies with the turn; a click
        // that opens the run can come minutes later.
        self.runs.add(
            off,
            self.shown.bytes().len - off,
            self.group.expanded,
            self.group.name,
            self.group.details.items,
            self.group.bodies.items,
        ) catch |err| log.debug("run record: {s}", .{@errorName(err)});
    }

    fn closeThinkTty(self: *Tty) void {
        const tail = self.think_view.end();
        if (tail.len == 0) return;
        if (chat.flushThink(self.allocator, self.layout.cols, &self.think)) |held| {
            defer self.allocator.free(held);
            if (held.len != 0) writeShown(self, held);
        } else |err| {
            log.debug("flush think: {s}", .{@errorName(err)});
        }
        writeShown(self, tail);
    }

    /// Commits anything a turn left buffered. Called when the turn ends, so a
    /// run that was still open is not silently dropped.
    pub fn flushGroups(self: *Live) void {
        switch (self.*) {
            .json, .stream => {},
            .tui => |*t| flushGroup(t),
        }
    }

    pub fn flushAsst(self: *Live) void {
        const t = switch (self.*) {
            .json, .stream => return,
            .tui => |*tty_live| tty_live,
        };
        if (t.asst_hold.items.len == 0) return;
        t.md.cols = t.layout.cols;
        const painted = t.md.line(t.allocator, t.asst_hold.items) catch {
            t.asst_hold.clearRetainingCapacity();
            return;
        };
        defer t.allocator.free(painted);
        writeShown(t, painted);
        t.asst_hold.clearRetainingCapacity();
    }

    /// The table a reply ended on: it is buffered until the block closes, and
    /// a reply whose last line is a table row closes it by ending.
    pub fn flushTable(self: *Live) void {
        const t = switch (self.*) {
            .json, .stream => return,
            .tui => |*tty_live| tty_live,
        };
        t.md.cols = t.layout.cols;
        const drawn = t.md.flush(t.allocator) catch return;
        defer t.allocator.free(drawn);
        if (drawn.len != 0) writeShown(t, drawn);
    }

    pub fn closeThink(self: *Live) void {
        switch (self.*) {
            .json => {},
            .stream => |*s| closeThinkStream(s),
            .tui => |*tty_live| closeThinkTty(tty_live),
        }
    }

    fn asLive(ctx: ?*anyopaque) ?*Live {
        const c = ctx orelse return null;
        return @ptrCast(@alignCast(c));
    }

    fn onText(ctx: ?*anyopaque, chunk: []const u8) void {
        const self = asLive(ctx) orelse return;
        switch (self.*) {
            .json => |j| emitJson(j.stdout, "text", chunk),
            .stream => |*s| {
                closeThinkStream(s);
                writeOut(s.stdout, chunk);
            },
            .tui => |*t| {
                closeThinkTty(t);
                // A run that is still buffered belongs above the text that
                // follows it, not after the whole reply at the end of the turn.
                flushGroup(t);
                t.act.text();
                var rest = chunk;
                while (rest.len > 0) {
                    const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
                        t.asst_hold.appendSlice(t.allocator, rest) catch {
                            writeShown(t, rest);
                            return;
                        };
                        previewAsst(t);
                        return;
                    };
                    t.asst_hold.appendSlice(t.allocator, rest[0..nl]) catch |err| {
                        log.debug("asst hold: {s}", .{@errorName(err)});
                    };
                    t.md.cols = t.layout.cols;
                    const painted = t.md.line(t.allocator, t.asst_hold.items) catch {
                        writeShown(t, rest[0 .. nl + 1]);
                        t.asst_hold.clearRetainingCapacity();
                        rest = rest[nl + 1 ..];
                        continue;
                    };
                    defer t.allocator.free(painted);
                    writeShown(t, painted);
                    t.asst_hold.clearRetainingCapacity();
                    rest = rest[nl + 1 ..];
                }
            },
        }
    }

    fn onThink(ctx: ?*anyopaque, chunk: []const u8) void {
        const self = asLive(ctx) orelse return;
        self.flushAsst();
        switch (self.*) {
            .json => |j| emitJson(j.stdout, "think", chunk),
            .stream => |*s| {
                if (!s.think_view.shows()) return;
                const frame = s.think_view.push(chunk) orelse return;
                if (!s.paint) {
                    writeOut(s.stdout, frame.body);
                    return;
                }
                if (frame.prefix.len > 0) {
                    s.think = .{};
                    writeOut(s.stdout, frame.prefix);
                }
                const painted = chat.formatThink(s.allocator, 80, frame.body, &s.think) catch {
                    writeOut(s.stdout, frame.body);
                    return;
                };
                defer s.allocator.free(painted);
                writeOut(s.stdout, painted);
            },
            .tui => |*t| {
                if (!t.think_view.shows()) {
                    paintTty(t, .none);
                    return;
                }
                const frame = t.think_view.push(chunk) orelse return;
                if (frame.prefix.len > 0) {
                    t.think = .{};
                    writeShown(t, frame.prefix);
                }
                const painted = chat.formatThink(t.allocator, t.layout.cols, frame.body, &t.think) catch {
                    writeShown(t, frame.body);
                    return;
                };
                defer t.allocator.free(painted);
                writeShown(t, painted);
            },
        }
    }

    fn onTool(ctx: ?*anyopaque, name: []const u8, detail: []const u8, done: bool, body: []const u8) void {
        const self = asLive(ctx) orelse return;
        self.flushAsst();
        switch (self.*) {
            .json => |j| {
                const st: []const u8 = if (done) "tool_end" else "tool_start";
                var buf: [240]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "{s} {s}", .{ name, detail }) catch return;
                emitJson(j.stdout, st, line);
                // Keep legacy `tool` for older hosts.
                var legacy: [240]u8 = undefined;
                const leg = std.fmt.bufPrint(&legacy, "{s} {s} {s}", .{ name, if (done) "done" else "run", detail }) catch return;
                emitJson(j.stdout, "tool", leg);
            },
            .stream => |*s| {
                closeThinkStream(s);
                if (!s.paint) {
                    var buf: [240]u8 = undefined;
                    const st: []const u8 = if (done) "done" else "run";
                    const line = std.fmt.bufPrint(&buf, "{s} {s} {s}\n", .{ name, st, detail }) catch return;
                    writeOut(s.stdout, line);
                    return;
                }
                const card = chat.formatTool(s.allocator, 80, name, detail, done, body) catch return;
                defer s.allocator.free(card);
                writeOut(s.stdout, card);
            },
            .tui => |*t| {
                closeThinkTty(t);
                if (!done) {
                    t.act.tool(name, detail);
                    paintTty(t, .none);
                    return;
                }
                // Failures never join a run: that is the card you need to read.
                const groupable = chat.statusOf(done, body) == .ok and chat.groupable(name);
                // A read says which lines it covered: "handbook.md" and
                // "handbook.md 1-250" are different amounts of information
                // about the same call.
                const shown_detail = readSpan(t.arena, name, detail, body);
                if (groupable and t.group.accepts(name)) {
                    t.group.push(t.arena, shown_detail, body);
                    // The live count is already on the activity line; the
                    // transcript gets the finished row when the run ends.
                    paintTty(t, .none);
                    return;
                }
                flushGroup(t);
                if (groupable) {
                    t.group.open(t.arena, name, shown_detail, body);
                    paintTty(t, .none);
                    return;
                }
                const card = chat.formatTool(t.allocator, t.layout.cols, name, shown_detail, done, body) catch return;
                defer t.allocator.free(card);
                writeShown(t, card);
            },
        }
    }

    fn onAsk(ctx: ?*anyopaque, name: []const u8, detail: []const u8) sink.Ask {
        const self = asLive(ctx) orelse return .deny;
        const t = switch (self.*) {
            .json => |j| {
                var buf: [240]u8 = undefined;
                const line = std.fmt.bufPrint(&buf, "deny {s} {s}", .{ name, detail }) catch "deny";
                emitJson(j.stdout, "permission", line);
                return .deny;
            },
            .stream => return .deny,
            .tui => |*tty_live| tty_live,
        };
        return switch (tui.askPerm(t.stdin, t.stdout, t.allocator, t.layout, t.footer.model, name, detail)) {
            .allow => .allow,
            .always => .always,
            .deny => .deny,
            .quit => {
                t.cancel.store(true, .release);
                return .deny;
            },
        };
    }

    /// `detail` with the read's line range appended, when there is one.
    fn readSpan(arena: std.mem.Allocator, name: []const u8, detail: []const u8, body: []const u8) []const u8 {
        if (!std.mem.eql(u8, name, "read")) return detail;
        const span = chat.lineSpan(body) orelse return detail;
        return std.fmt.allocPrint(arena, "{s} {d}-{d}", .{ detail, span.from, span.to }) catch detail;
    }

    fn onUsage(ctx: ?*anyopaque, input: u32, output: u32, read: u32, write: u32) void {
        const self = asLive(ctx) orelse return;
        switch (self.*) {
            .json, .stream => {},
            .tui => |*t| {
                t.act.usage(input, output, read, write);
                paintTty(t, .none);
            },
        }
    }

    fn onTick(ctx: ?*anyopaque) void {
        const self = asLive(ctx) orelse return;
        switch (self.*) {
            .json, .stream => {},
            .tui => |*t| paintTty(t, .none),
        }
    }

    fn spinLoop(t: *Tty) void {
        while (!t.spin_stop.load(.acquire)) {
            var spec = std.c.timespec{ .sec = 0, .nsec = activity.spin_ms * std.time.ns_per_ms };
            _ = std.c.nanosleep(&spec, null);
            if (t.spin_stop.load(.acquire)) break;
            paintTty(t, .none);
        }
    }

    fn startSpinTty(t: *Tty) void {
        if (t.spin_thread != null) return;
        t.spin_stop.store(false, .release);
        t.spin_thread = std.Thread.spawn(.{}, spinLoop, .{t}) catch |err| {
            log.warn("spinner: {s}", .{@errorName(err)});
            return;
        };
    }

    fn stopSpinTty(t: *Tty) void {
        t.spin_stop.store(true, .release);
        if (t.spin_thread) |th| th.join();
        t.spin_thread = null;
    }

    /// Keeps the status glyph moving before the HTTP watcher exists (connect,
    /// follow-up reflection) and while the socket is quiet.
    pub fn startSpin(self: *Live) void {
        switch (self.*) {
            .tui => |*t| startSpinTty(t),
            .json, .stream => {},
        }
    }

    pub fn stopSpin(self: *Live) void {
        switch (self.*) {
            .tui => |*t| stopSpinTty(t),
            .json, .stream => {},
        }
    }

    pub fn host(self: *Live) sink.Host {
        const cancel: *std.atomic.Value(bool) = switch (self.*) {
            .json => |*j| j.cancel,
            .stream => |*s| s.cancel,
            .tui => |*t| t.cancel,
        };
        return .{
            .ctx = self,
            .on_text = onText,
            .on_usage = onUsage,
            .on_tick = onTick,
            .on_think = onThink,
            .on_tool = onTool,
            .ask = onAsk,
            .cancel = cancel,
        };
    }
};

pub fn json(stdout: *Io.Writer, cancel: *std.atomic.Value(bool)) Live {
    return .{ .json = .{ .stdout = stdout, .cancel = cancel } };
}

pub fn stream(stdout: *Io.Writer, cancel: *std.atomic.Value(bool), allocator: std.mem.Allocator, think_view: tui.ThinkView, paint: bool) Live {
    return .{ .stream = .{
        .stdout = stdout,
        .cancel = cancel,
        .allocator = allocator,
        .think_view = think_view,
        .paint = paint,
    } };
}

pub fn tty(args: Live.Tty) Live {
    return .{ .tui = args };
}

pub fn emitJson(stdout: *Io.Writer, kind: []const u8, chunk: []const u8) void {
    stdout.writeAll("{\"type\":\"") catch return;
    stdout.writeAll(kind) catch return;
    stdout.writeAll("\",\"text\":\"") catch return;
    for (chunk) |c| switch (c) {
        '"' => stdout.writeAll("\\\"") catch return,
        '\\' => stdout.writeAll("\\\\") catch return,
        '\n' => stdout.writeAll("\\n") catch return,
        '\r' => {},
        else => stdout.writeByte(c) catch return,
    };
    stdout.writeAll("\"}\n") catch return;
    stdout.flush() catch |err| {
        log.debug("json flush: {s}", .{@errorName(err)});
    };
}

test "emitJson escapes quotes and newlines" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    emitJson(&aw.writer, "text", "a\"b\nc");
    try std.testing.expectEqualStrings("{\"type\":\"text\",\"text\":\"a\\\"b\\nc\"}\n", aw.written());
}

test "Live json and stream tags are exclusive" {
    var cancel: std.atomic.Value(bool) = .init(false);
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    const j = json(&aw.writer, &cancel);
    const s = stream(&aw.writer, &cancel, std.testing.allocator, .hidden, true);
    try std.testing.expectEqual(.json, std.meta.activeTag(j));
    try std.testing.expectEqual(.stream, std.meta.activeTag(s));
}

test "json host emits text events" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var live = json(&aw.writer, &cancel);
    live.host().text("hi");
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"type\":\"text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "hi") != null);
}

test "stream host paints tool cards" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var live = stream(&aw.writer, &cancel, std.testing.allocator, .hidden, true);
    live.host().toolOut("read", "src/main.zig", true, "hello\n");
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "Read") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "src/main.zig") != null);
}

test "stream without paint emits no SGR" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var live = stream(&aw.writer, &cancel, std.testing.allocator, .hidden, false);
    live.host().toolOut("read", "src/main.zig", true, "hello\n");
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\x1b[") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "src/main.zig") != null);
}

test "json host deny is the ask result" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);
    var live = json(&aw.writer, &cancel);
    try std.testing.expectEqual(sink.Ask.deny, live.host().decide("bash", "rm").?);
}

const TtyCase = struct {
    aw: std.Io.Writer.Allocating,
    cancel: std.atomic.Value(bool),
    layout: tui.Layout,
    asst_hold: std.ArrayList(u8),
    md: chat.Markdown,
    scroll: usize,
    stdin: Io.Reader,
    shown: tui.Transcript,
    act: Live.Act,
    scratch: std.heap.ArenaAllocator,
    run: Live.Run,
    runs: runs_mod.Store,
    live: Live,

    fn setup(self: *TtyCase, cols: u16, footer: tui.Footer) void {
        self.aw = .init(std.testing.allocator);
        self.cancel = .init(false);
        self.layout = tui.Layout.compute(24, cols);
        self.asst_hold = .empty;
        self.md = .{};
        self.scroll = 0;
        self.stdin = Io.Reader.fixed("");
        self.shown = tui.Transcript.init(std.testing.allocator, cols);
        self.act = .{};
        self.act.begin();
        self.scratch = .init(std.testing.allocator);
        self.run = .{};
        self.runs = runs_mod.Store.init(std.testing.allocator);
        self.live = tty(.{
            .stdout = &self.aw.writer,
            .stdin = &self.stdin,
            .allocator = std.testing.allocator,
            .layout = &self.layout,
            .footer = footer,
            .cancel = &self.cancel,
            .shown = &self.shown,
            .think_view = .hidden,
            .asst_hold = &self.asst_hold,
            .md = &self.md,
            .act = &self.act,
            .group = &self.run,
            .runs = &self.runs,
            .arena = self.scratch.allocator(),
            .scroll = &self.scroll,
        });
    }

    fn deinit(self: *TtyCase) void {
        self.asst_hold.deinit(std.testing.allocator);
        self.runs.deinit();
        self.md.deinit(std.testing.allocator);
        self.shown.deinit();
        self.scratch.deinit();
        self.aw.deinit();
    }
};

fn ttyFooter() tui.Footer {
    return .{
        .model = "x",
        .permission = "ask",
        .composer = "",
        .place = "/tmp",
        .turn = .generating,
    };
}

test "renderNow elapsed is from the wall clock" {
    var act = Live.Act{};
    act.begin();
    _ = act.renderNow();
    try std.testing.expect(act.state.elapsed_ms >= 0);
    try std.testing.expect(act.state.elapsed_ms < activity.show_after_ms);
}

test "tui host paints through writePane" {
    var case: TtyCase = undefined;
    case.setup(80, ttyFooter());
    defer case.deinit();
    case.live.host().text("hello\n");
    const out = case.aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Waiting for response") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, tui.stop_hint) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, tui.hide_cursor) != null);
    // The composer takes steering while the turn runs, so the caret stays.
    try std.testing.expect(std.mem.indexOf(u8, out, tui.show_cursor) != null);
}

test "tool activity is the same words in the pane and the tab title" {
    var case: TtyCase = undefined;
    case.setup(80, ttyFooter());
    defer case.deinit();
    case.live.host().tool("read", "Scan the live paint path", false);
    const out = case.aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "Scan the live paint path") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b]0;") != null);
    var found_glyph = false;
    for (activity.glyphs) |g| {
        if (std.mem.indexOf(u8, out, g) != null) found_glyph = true;
    }
    try std.testing.expect(found_glyph);
    try std.testing.expect(std.mem.indexOf(u8, out, "Generating") == null);
}

test "hidden think still refreshes the status spinner" {
    var case: TtyCase = undefined;
    case.setup(80, ttyFooter());
    defer case.deinit();
    case.live.host().think("secret plan");
    const out = case.aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "Waiting for response") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "secret plan") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "omfx") != null);
}

test "a run of the same tool collapses into one transcript row" {
    var case: TtyCase = undefined;
    case.setup(100, ttyFooter());
    defer case.deinit();
    const host = case.live.host();
    const files = [_][]const u8{ "a.zig", "b.zig", "c.zig", "d.zig" };
    for (files) |f| {
        host.tool("read", f, false);
        host.toolOut("read", f, true, "contents\n");
    }
    case.live.flushGroups();
    const body = case.shown.bytes();
    try std.testing.expect(std.mem.indexOf(u8, body, "Read 4 files") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\u{25b8}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "d.zig") != null);
}

test "a different tool ends the run, and a failure never collapses" {
    var case: TtyCase = undefined;
    case.setup(100, ttyFooter());
    defer case.deinit();
    const host = case.live.host();
    host.toolOut("read", "a.zig", true, "ok\n");
    host.toolOut("read", "b.zig", true, "ok\n");
    host.toolOut("bash", "ls", true, "ok\n");
    host.toolOut("bash", "boom", true, "tool error: nope\n");
    case.live.flushGroups();
    const body = case.shown.bytes();
    try std.testing.expect(std.mem.indexOf(u8, body, "Read 2 files") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "tool error: nope") != null);
}
