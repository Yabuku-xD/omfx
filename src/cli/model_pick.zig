const std = @import("std");
const Io = std.Io;

const log = std.log.scoped(.model_pick);

const cmd_ctx = @import("cmd_ctx.zig");
const Ctx = cmd_ctx.Ctx;
const State = cmd_ctx.State;
const emit = cmd_ctx.emit;
const readAuth = cmd_ctx.readAuth;
const persistChat = cmd_ctx.persistChat;
const refreshInto = cmd_ctx.refreshInto;

const config = @import("../core/config.zig");
const settings = @import("../core/settings.zig");
const catalog = @import("../providers/catalog.zig");
const auth = @import("../providers/auth.zig");
const models = @import("../providers/models.zig");
const registry = @import("../providers/registry.zig");
const types = @import("../providers/types.zig");

/// Not a provider level: omfx resolves it to one of the model's own before the
/// request goes out. See `core/autoeffort.zig`.
pub const auto_effort = "auto";

fn modelDisplay(id: []const u8, provider: []const u8) []const u8 {
    if (models.lookup(provider, id)) |m| return m.name;
    if (catalog.byId(id)) |spec| return spec.name;
    return id;
}

pub fn noteUsing(ctx: *Ctx, id: []const u8) !void {
    const provider = if (ctx.state.resolved) |r| r.spec.id else "";
    const label = modelDisplay(id, provider);
    const m = describeModel(ctx, provider, id) orelse {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Using {s}.\n", .{label}));
        return;
    };
    // The window and the levels are what change between models, so they are
    // what the confirmation says.
    if (m.context_window == 0 and m.efforts.len == 0) {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Using {s}.\n", .{label}));
        return;
    }
    if (m.efforts.len == 0) {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Using {s}. It holds {d}k of context.\n", .{ label, m.context_window / 1000 }));
        return;
    }
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Using {s}. It holds {d}k of context and offers auto, {s}.\n", .{
        label,
        m.context_window / 1000,
        effortList(ctx.arena, m.efforts),
    }));
}

fn modelRowWanted(id: []const u8, help: []const u8, rest: []const u8) bool {
    if (rest.len == 0) return true;
    return std.mem.indexOf(u8, id, rest) != null or std.mem.indexOf(u8, help, rest) != null;
}

pub fn fillProviders(state: *State, rest: []const u8) void {
    state.pick.open(.providers);
    for (catalog.all) |spec| {
        if (!modelRowWanted(spec.id, spec.name, rest) and !modelRowWanted(spec.id, spec.model, rest)) continue;
        state.pick.pushFlipped(spec.id, spec.name);
    }
}

fn vendorOf(provider: []const u8) types.Vendor {
    if (std.mem.startsWith(u8, provider, "anthropic")) return .anthropic;
    if (std.mem.startsWith(u8, provider, "xai")) return .xai;
    return .openai;
}

fn providerModels(ctx: *Ctx, provider: []const u8) *const registry.List {
    if (ctx.state.registry_of.len != 0 and std.mem.eql(u8, ctx.state.registry_of, provider)) {
        return &ctx.state.registry;
    }
    // The list is per key: what a provider serves depends on who is asking.
    const key = if (ctx.state.resolved) |r| r.api_key else "";
    const base = if (ctx.state.resolved) |r| r.base_url else if (catalog.byId(provider)) |spec| spec.base_url else "";
    const vendor = vendorOf(provider);
    registry.load(
        ctx.gpa,
        ctx.io,
        ctx.home,
        provider,
        base,
        key,
        vendor,
        &ctx.state.registry,
    );
    ctx.state.registry_of = provider;
    return &ctx.state.registry;
}

pub fn describeModel(ctx: *Ctx, provider: []const u8, id: []const u8) ?models.Model {
    const built = models.lookup(provider, id);
    const live = providerModels(ctx, provider);
    const e = live.find(id) orelse return built;
    const base = built orelse models.Model{
        .id = e.id(),
        .name = e.name(),
        .provider = provider,
        .protocol = if (catalog.byId(provider)) |spec| spec.protocol else .openai_compat,
        .base_url = if (catalog.byId(provider)) |spec| spec.base_url else "",
        .reasoning = e.efforts().len != 0,
        .context_window = 0,
        .max_tokens = 0,
        .efforts = "",
        .vision = false,
    };
    return registry.merge(base, e);
}

pub fn modelSummary(buf: []u8, m: models.Model) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeWindow(&w, m.context_window) catch return "";
    w.writeAll(if (m.vision) "  \u{b7}  text+vision" else "  \u{b7}  text") catch return "";
    if (m.efforts.len != 0) {
        w.writeAll("  \u{b7}  ") catch return "";
        w.writeAll(m.efforts) catch return "";
    }
    return w.buffered();
}

fn writeWindow(w: *std.Io.Writer, tokens: u32) !void {
    if (tokens == 0) return w.writeAll("window unknown");
    if (tokens < 1_000_000) return w.print("{d}k", .{tokens / 1000});
    return w.print("{d}.{d}M", .{ tokens / 1_000_000, (tokens % 1_000_000) / 100_000 });
}

fn pushModel(ctx: *Ctx, provider: []const u8, id: []const u8) void {
    const m = describeModel(ctx, provider, id) orelse {
        ctx.state.pick.push(id, "");
        return;
    };
    var buf: [96]u8 = undefined;
    ctx.state.pick.push(id, modelSummary(&buf, m));
}

pub fn fillModelsFor(ctx: *Ctx, provider: []const u8) void {
    ctx.state.pick.open(.models);
    // The provider's list first: it knows about models shipped after this
    // binary was built, which is the whole reason for asking.
    const live = providerModels(ctx, provider);
    if (live.n != 0) {
        // The ids are copied out first: pushing reads `ctx.state.registry`,
        // which is what `live` points into.
        var ids: [registry.max_models][96]u8 = undefined;
        var lens: [registry.max_models]usize = undefined;
        const n = live.n;
        for (live.slice(), 0..) |*e, i| {
            lens[i] = @min(e.id().len, ids[i].len);
            @memcpy(ids[i][0..lens[i]], e.id()[0..lens[i]]);
        }
        for (0..n) |i| pushModel(ctx, provider, ids[i][0..lens[i]]);
        return;
    }
    var buf: [48]models.Model = undefined;
    const got = models.forProvider(provider, &buf);
    if (got > 0) {
        for (buf[0..got]) |m| {
            var row: [96]u8 = undefined;
            ctx.state.pick.push(m.id, modelSummary(&row, m));
        }
        return;
    }
    if (catalog.byId(provider)) |spec| {
        pushModel(ctx, provider, spec.model);
    }
}

pub fn fillEffortsFor(ctx: *Ctx, provider: []const u8, id: []const u8) bool {
    const m = describeModel(ctx, provider, id) orelse return false;
    if (m.efforts.len == 0) return false;
    ctx.state.pick.open(.efforts);
    // `auto` is offered by omfx, not by the provider, so it leads: it is the
    // one entry that reads the prompt instead of being told.
    ctx.state.pick.push(auto_effort, "pick per prompt");
    var it = std.mem.splitScalar(u8, m.efforts, ',');
    while (it.next()) |level| {
        if (level.len == 0) continue;
        ctx.state.pick.push(level, "");
    }
    return ctx.state.pick.n > 1;
}

pub fn doModels(ctx: *Ctx, rest: []const u8) !void {
    const arg = std.mem.trim(u8, rest, " \t");
    const provider = if (ctx.state.resolved) |r| r.spec.id else "";
    if (provider.len == 0) {
        try emit(ctx, "Not signed in yet. Run /login to pick a provider.\n");
        return;
    }
    if (arg.len == 0) {
        fillModelsFor(ctx, provider);
        if (ctx.state.pick.n == 0) try emit(ctx, "This provider lists no models.\n");
        return;
    }
    if (std.mem.eql(u8, arg, "refresh")) {
        try refreshModels(ctx, provider);
        return;
    }
    try doModel(ctx, arg);
}

fn refreshModels(ctx: *Ctx, provider: []const u8) !void {
    ctx.state.registry_of = "";
    ctx.state.registry.n = 0;
    const live = providerModels(ctx, provider);
    if (live.n == 0) {
        try emit(ctx, try std.fmt.allocPrint(
            ctx.arena,
            "{s} publishes no model list, so the built-in table is in use.\n",
            .{provider},
        ));
        return;
    }
    // What a provider lists depends on the credential, so the count is
    // reported against the login that asked for it.
    const cap = registry.authCap(provider);
    if (cap != 0) {
        try emit(ctx, try std.fmt.allocPrint(
            ctx.arena,
            "{d} models from {s}. This login caps context at {d}k.\n",
            .{ live.n, provider, cap / 1000 },
        ));
        return;
    }
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "{d} models from {s}.\n", .{ live.n, provider }));
}

pub fn bindProvider(ctx: *Ctx, id: []const u8) !void {
    const spec = catalog.byId(id) orelse {
        ctx.state.pick.clear();
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "unknown provider {s}\n", .{id}));
        return;
    };
    const json = readAuth(ctx.arena, ctx.io, ctx.home);
    const key = auth.resolveKey(ctx.lookup, json, spec) orelse {
        ctx.state.pick.clear();
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "no key for {s}; /login {s}\n", .{ spec.id, spec.id }));
        return;
    };
    const base = ctx.lookup.get("OMFX_BASE_URL") orelse spec.base_url;
    ctx.state.resolved = .{ .spec = spec, .api_key = key, .base_url = base, .model = spec.model };
    ctx.state.model_override = null;
    refreshInto(ctx, false);
    persistChat(ctx);
}

pub fn stepPickBack(state: *State) bool {
    // Models no longer sit under a provider list, so there is nothing behind
    // them to step back to: closing is the only way out.
    if (state.pick.kind != .none) {
        state.pick.clear();
        return true;
    }
    return false;
}

pub fn doModel(ctx: *Ctx, rest: []const u8) !void {
    if (rest.len == 0) {
        if (ctx.state.resolved) |r| {
            try noteUsing(ctx, r.model);
        } else {
            try emit(ctx, "Not signed in yet. Run /login to pick a provider.\n");
        }
        return;
    }
    if (ctx.state.resolved) |*r| {
        if (models.lookup(r.spec.id, rest)) |m| {
            r.model = try ctx.arena.dupe(u8, m.id);
            ctx.state.model_override = r.model;
            try noteUsing(ctx, m.id);
            return;
        }
    }
    if (catalog.byId(rest)) |spec| {
        try bindProvider(ctx, spec.id);
        if (ctx.state.resolved == null) return;
        fillModelsFor(ctx, spec.id);
        if (ctx.state.pick.n == 0) {
            ctx.state.pick.clear();
            try noteUsing(ctx, spec.model);
        }
        return;
    }
    var found: ?catalog.Spec = null;
    for (catalog.all) |spec| {
        if (std.mem.indexOf(u8, spec.id, rest) != null or std.mem.indexOf(u8, spec.model, rest) != null) {
            if (found != null) {
                fillProviders(ctx.state, rest);
                return;
            }
            found = spec;
        }
    }
    if (found) |spec| {
        try doModel(ctx, spec.id);
        return;
    }
    if (ctx.state.resolved) |*r| {
        r.model = try ctx.arena.dupe(u8, rest);
        ctx.state.model_override = r.model;
        try noteUsing(ctx, rest);
    } else {
        try emit(ctx, "No provider yet. Run /login first.\n");
    }
}

fn currentEfforts(ctx: *Ctx) ?[]const u8 {
    const r = ctx.state.resolved orelse return null;
    const m = describeModel(ctx, r.spec.id, r.model) orelse return null;
    return m.efforts;
}

pub fn doEffort(ctx: *Ctx, rest: []const u8) !void {
    const known = currentEfforts(ctx);
    if (rest.len == 0) {
        const cur = if (ctx.state.effort.len == 0) auto_effort else ctx.state.effort;
        const supported = known orelse {
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "effort={s}\n", .{cur}));
            return;
        };
        if (supported.len == 0) {
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Reasoning is {s}. This model has no levels to choose from.\n", .{cur}));
            return;
        }
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Reasoning is set to {s}. This model offers auto, {s}.\n", .{ cur, effortList(ctx.arena, supported) }));
        return;
    }
    const supported = known orelse {
        // No model bound yet, so there is nothing to check against.
        if (config.Effort.fromSlice(rest)) |e| {
            ctx.state.effort = e.asSlice();
            ctx.state.fast = false;
            try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Reasoning set to {s}.\n", .{ctx.state.effort}));
        } else {
            try emit(ctx, "Pick a level this model offers: /effort <level>.\n");
        }
        return;
    };
    // A level the model does not declare is rejected by the provider, so it is
    // refused here where the message can name what the model does take.
    if (supported.len == 0) {
        try emit(ctx, "This model has no reasoning levels to set.\n");
        return;
    }
    if (!std.mem.eql(u8, rest, auto_effort) and !effortListed(supported, rest)) {
        try emit(ctx, try std.fmt.allocPrint(ctx.arena, "This model does not take {s}. It offers auto, {s}.\n", .{ rest, effortList(ctx.arena, supported) }));
        return;
    }
    ctx.state.effort = try ctx.arena.dupe(u8, rest);
    ctx.state.fast = false;
    try emit(ctx, try std.fmt.allocPrint(ctx.arena, "Reasoning set to {s}.\n", .{ctx.state.effort}));
}

pub fn cycleEffort(ctx: *Ctx) !void {
    const supported = currentEfforts(ctx) orelse "";
    if (supported.len == 0) {
        try emit(ctx, "This model has no reasoning levels to set.\n");
        return;
    }
    var levels: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, supported, ',');
    while (it.next()) |level| {
        if (level.len == 0 or n == levels.len) continue;
        levels[n] = level;
        n += 1;
    }
    if (n == 0) return;
    // `auto` is one stop on the ring, so the cycle can get back to letting
    // the prompt decide.
    var at: usize = n;
    for (levels[0..n], 0..) |level, i| {
        if (std.mem.eql(u8, level, ctx.state.effort)) at = i;
    }
    const next = (at + 1) % (n + 1);
    ctx.state.effort = if (next == n) auto_effort else try ctx.arena.dupe(u8, levels[next]);
    ctx.state.fast = false;
    settings.setPref(ctx.gpa, ctx.io, ctx.home, .effort, ctx.state.effort) catch |err| {
        log.warn("effort: {s}", .{@errorName(err)});
    };
}

pub fn effortList(arena: std.mem.Allocator, list: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, list, ',');
    var first = true;
    while (it.next()) |level| {
        if (level.len == 0) continue;
        if (!first) out.appendSlice(arena, ", ") catch return list;
        out.appendSlice(arena, level) catch return list;
        first = false;
    }
    return out.items;
}

fn effortListed(list: []const u8, want: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |level| {
        if (std.mem.eql(u8, level, want)) return true;
    }
    return false;
}

