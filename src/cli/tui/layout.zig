const std = @import("std");
const builtin = @import("builtin");

pub const Size = struct { rows: u16, cols: u16 };

fn winsizeOn(fd: std.posix.fd_t) ?Size {
    var wsz: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const req: u32 = @truncate(std.posix.T.IOCGWINSZ);
    const rc = std.c.ioctl(fd, @bitCast(req), &wsz);
    if (rc < 0 or wsz.row == 0 or wsz.col == 0) return null;
    return .{ .rows = wsz.row, .cols = wsz.col };
}

pub fn size(fallback_rows: u16, fallback_cols: u16) Size {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) {
        return .{ .rows = fallback_rows, .cols = fallback_cols };
    }
    if (winsizeOn(std.posix.STDOUT_FILENO)) |s| return s;
    if (winsizeOn(std.posix.STDIN_FILENO)) |s| return s;
    return .{ .rows = fallback_rows, .cols = fallback_cols };
}

pub fn moveTo(buf: []u8, row: u16, col: u16) ![]u8 {
    return std.fmt.bufPrint(buf, "\x1b[{d};{d}H", .{ row, col });
}

pub const Layout = struct {
    rows: u16,
    cols: u16,
    header_rows: u16,
    footer_rows: u16,
    transcript_rows: u16,
    transcript_start_row: u16,
    footer_start_row: u16,

    pub fn compute(rows: u16, cols: u16) Layout {
        const header_rows: u16 = if (rows >= 6) 1 else 0;
        const footer_rows: u16 = if (rows >= 8) 4 else if (rows >= 5) 3 else if (rows >= 3) 2 else 1;
        const used = header_rows + footer_rows;
        const transcript_rows = if (rows > used) rows - used else 0;
        const transcript_start_row: u16 = header_rows + 1;
        const footer_start_row = if (transcript_rows == 0)
            transcript_start_row
        else
            transcript_start_row + transcript_rows;
        return .{
            .rows = rows,
            .cols = if (cols == 0) 1 else cols,
            .header_rows = header_rows,
            .footer_rows = footer_rows,
            .transcript_rows = transcript_rows,
            .transcript_start_row = transcript_start_row,
            .footer_start_row = footer_start_row,
        };
    }

    pub fn regionTop(self: Layout) u16 {
        return self.transcript_start_row;
    }

    pub fn regionBottom(self: Layout) u16 {
        if (self.transcript_rows == 0) return self.transcript_start_row;
        return self.transcript_start_row + self.transcript_rows - 1;
    }

    /// Last scroll row when an overlay of `overlay_h` rows sits above the footer.
    /// Overlay rows are not in the scroll region, so command output cannot push them up.
    pub fn scrollBottom(self: Layout, overlay_h: u16) u16 {
        const full = self.regionBottom();
        if (overlay_h == 0) return full;
        const cut = self.footer_start_row -| overlay_h;
        if (cut <= self.transcript_start_row) return self.transcript_start_row;
        return cut - 1;
    }
};

/// Sticky chrome cups. Recomputed after every resize so menus stay on the transcript.
pub const Cups = struct {
    transcript: [32]u8 = undefined,
    transcript_len: usize = 0,
    footer: [32]u8 = undefined,
    footer_len: usize = 0,

    pub fn compute(layout: Layout) Cups {
        var c = Cups{};
        const t = moveTo(&c.transcript, layout.regionBottom(), 1) catch return c;
        c.transcript_len = t.len;
        const f = moveTo(&c.footer, layout.footer_start_row, 1) catch return c;
        c.footer_len = f.len;
        return c;
    }

    pub fn toTranscript(self: *const Cups) []const u8 {
        return self.transcript[0..self.transcript_len];
    }

    pub fn toFooter(self: *const Cups) []const u8 {
        return self.footer[0..self.footer_len];
    }
};
