windows_window: vaxis.Window,
status_window: vaxis.Window,
text_splits: std.ArrayListUnmanaged(TextWindow) = .{},
current_split_index: u32 = 0,
mode: Mode = .normal,
quit: bool = false,
status_buffer: StatusBuffer = .{},

keybind_handler: KeyBindHandler = .{},

const Ctx = @This();

const SplitFlavor = enum {
    vertical,
    horizontal,
};

pub fn deinit(ctx: *Ctx, allocator: Allocator) void {
    for (ctx.text_splits.items) |*split| {
        split.text_buffer.deinit(allocator);
    }
    ctx.text_splits.deinit(allocator);
    ctx.* = undefined;
}

pub fn activeTextWindow(ctx: Ctx) *TextWindow {
    // gaurenteed to always have a window open
    assert(ctx.text_splits.items.len > 0);
    return &ctx.text_splits.items[ctx.current_split_index];
}

pub fn handleKeyPress(ctx: *Ctx, allocator: Allocator, vaxis_key: vaxis.Key) !void {
    const key = keybind.Key.fromVaxisKey(vaxis_key);
    if (try ctx.keybind_handler.handleKeyPress(ctx, allocator, key) == .not_consumed) {
        switch (ctx.mode) {
            .normal => {},
            .insert => {

                if (key.codepoint == .BS) {
                    try ctx.activeTextWindow().text_buffer.deleteChar(allocator);
                } else if(key.codepoint == .CR) {
                    try ctx.activeTextWindow().text_buffer.newline(allocator);
                } else {
                    const ascii_key = std.math.cast(u8, @intFromEnum(key.codepoint)) orelse return;
                    try ctx.activeTextWindow().text_buffer.writeChar(allocator, ascii_key);
                }
            },
            .command => {
                if (key.codepoint == .BS) {
                    if (ctx.status_buffer.cursor == 0) return;
                    _ = ctx.status_buffer.text.orderedRemove(ctx.status_buffer.cursor);
                    ctx.status_buffer.cursor -= 1;
                } else {
                    const ascii_key = std.math.cast(u8, @intFromEnum(key.codepoint)) orelse return;
                    try ctx.status_buffer.text.insert(ctx.status_buffer.cursor + 1, ascii_key);
                    ctx.status_buffer.cursor += 1;
                }
            },
        }
    }
}

pub fn render(ctx: *Ctx) !void {
    // TODO: render tabs as spaces
    // render text buffers
    for (ctx.text_splits.items) |text_split| {
        const tb = text_split.text_buffer;
        const win = text_split.window;
        for (tb.lines.items, 0..) |line, y| {
            var segment = vaxis.Cell.Segment{
                .text = line.items,
            };
            _ = try win.print(
                (&segment)[0..1],
                .{ .row_offset = y },
            );
        }
        const tildas_count = ctx.windows_window.height - tb.lines.items.len;
        const tilda_cell = vaxis.Cell{
            .char = .{ .grapheme = "~", .width = 1 },
            .style = .{
                .fg = .{ .rgb = .{ 0xCC, 0xCC, 0xCC } },
            },
        };
        for (0..tildas_count, tb.lines.items.len..) |_, y| {
            win.writeCell(0, y, tilda_cell);
        }
    }
    // render cursor
    // in command mode, draw it in the status buffer
    // in any other mode, draw it in the current text window
    const cursor_shape: vaxis.Cell.CursorShape = switch (ctx.mode) {
        .insert, .command => .beam,
        .normal => .block,
    };
    if (ctx.mode == .command) {
        ctx.status_window.setCursorShape(cursor_shape);
        ctx.status_window.showCursor(ctx.status_buffer.cursor + 1, 0);
    } else {
        const tw = ctx.activeTextWindow();
        const tb = tw.text_buffer;
        tw.window.setCursorShape(cursor_shape);
        tw.window.showCursor(tb.cursor_x, tb.cursor_y);
    }
    // if not in command mode, render debug info
    // if in command mode, the status_buffer should already have the text in it
    if (ctx.mode != .command and false) {
        ctx.status_buffer.text.len = 0;
        const tw = ctx.activeTextWindow();
        try ctx.status_buffer.text.writer().print("{[mode]s}|({[cx]?},{[cy]?})", .{
            .mode = switch (ctx.mode) {
                .insert => "I",
                .normal => "N",
                .command => unreachable,
            },
            .cx = tw.text_buffer.cursor_x,
            .cy = tw.text_buffer.cursor_y,
        });
    }
    // render status/command buffer
    var status_segment = vaxis.Cell.Segment{
        .text = ctx.status_buffer.text.slice(),
    };
    _ = try ctx.status_window.print((&status_segment)[0..1], .{});
}

pub fn addSplit(ctx: *Ctx, allocator: Allocator, file_path: ?[]const u8, flavor: SplitFlavor) !void {
    const tw = ctx.activeTextWindow();
    const win = &tw.window;

    const new_width, const new_height = switch (flavor) {
        .horizontal => .{ @divFloor(win.width, 2), win.height },
        .vertical => .{ win.width, @divFloor(win.height, 2) },
    };

    win.* = ctx.windows_window.child(.{
        .x_off = win.x_off,
        .y_off = win.y_off,
        .width = .{ .limit = new_width },
        .height = .{ .limit = new_height },
    });

    const new_x_off, const new_y_off = switch (flavor) {
        .horizontal => .{ win.x_off + win.width, win.y_off },
        .vertical => .{ win.x_off, win.y_off + win.height },
    };
    const new_win = ctx.windows_window.child(.{
        .x_off = new_x_off,
        .y_off = new_y_off,
        .width = .{ .limit = new_width },
        .height = .{ .limit = new_height },
    });

    const text_buffer = blk: {
        if (file_path) |path| {
            const str = try readOrCreateFile(allocator, path);
            break :blk try TextBuffer.init(allocator, str orelse "");
        } else {
            break :blk try TextBuffer.init(allocator, "");
        }
    };
    try ctx.text_splits.append(allocator, .{
        .window = new_win,
        .text_buffer = text_buffer,
    });
}

pub fn readOrCreateFile(allocator: Allocator, path: []const u8) !?[]const u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch |err| {
        switch (err) {
            error.FileNotFound => {
                _ = try std.fs.cwd().createFile(path, .{});
                return null;
            },
            else => |e| return e,
        }
    };
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    _ = try f.readAll(buf);
    return buf;
}

pub fn loadDefaultWindow(ctx: *Ctx, allocator: Allocator) !void {
    assert(ctx.text_splits.items.len == 0);

    const win = ctx.windows_window;
    const child = win.child(.{
        .x_off = 0,
        .y_off = 0,
        .width = .{ .limit = win.width },
        .height = .{ .limit = win.height },
    });

    ctx.text_splits.append(allocator, .{
        .text_buffer = try TextBuffer.init(allocator, ""),
        .window = child,
    }) catch unreachable;
}

const Mode = enum {
    normal,
    command,
    insert,
};

const TextWindow = struct {
    text_buffer: TextBuffer,
    window: vaxis.Window,
};

const MAX_STATUS_BUFFER_LEN = 1024 * 8;

const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");
const TextBuffer = @import("TextBuffer.zig");
const Allocator = std.mem.Allocator;
const StatusBuffer = @import("StatusBuffer.zig");
const runCommand = @import("commands.zig").runCommand;
const keybind = @import("keybind.zig");
const KeyBindHandler = keybind.KeyBindHandler;
