//! This benchmark tests the cost of turning terminal rows into text runs
//! and shaping them, which the renderer does for every dirty row on every
//! frame. Shaped runs are cached by the renderer, but run iteration is not,
//! so the `runs` mode measures the per-frame cost that a cache can't hide.
const ShaperRows = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Benchmark = @import("Benchmark.zig");
const options = @import("options.zig");
const font = @import("../font/main.zig");
const terminalpkg = @import("../terminal/main.zig");
const Terminal = terminalpkg.Terminal;

const log = std.log.scoped(.@"shaper-rows-bench");

opts: Options,
lib: font.Library,
grid: *font.SharedGrid,
shaper: font.Shaper,
terminal: Terminal,
state: terminalpkg.RenderState = .empty,

pub const Options = struct {
    /// Which part of the shaping pipeline to run.
    mode: Mode = .shape,

    /// The size of the terminal. Every row is processed on each pass.
    @"terminal-rows": u16 = 80,
    @"terminal-cols": u16 = 120,

    /// How many passes over the screen to make. Each pass is roughly
    /// one full-screen frame rebuild.
    iterations: u32 = 200,

    /// The data to read as a filepath. If this is "-" then we will read
    /// stdin. The data is written to the terminal during setup, which is
    /// not part of the benchmark; the visible screen is then processed.
    data: ?[]const u8 = null,
};

pub const Mode = enum {
    /// Split rows into runs, without shaping them.
    runs,

    /// Split rows into runs and shape every run.
    shape,
};

pub fn create(
    alloc: Allocator,
    opts: Options,
) !*ShaperRows {
    var lib = try font.Library.init(alloc);
    errdefer lib.deinit();

    // A monospace Latin face first, then an embedded Arabic-script face
    // so RTL input is shaped by a real font rather than falling back.
    var c = font.Collection.init();
    c.load_options = .{ .library = lib };
    for ([_][:0]const u8{ font.embedded.inconsolata, font.embedded.arabic }) |data| {
        _ = try c.add(alloc, try .init(
            lib,
            data,
            .{ .size = .{ .points = 12 } },
        ), .{
            .style = .regular,
            .fallback = false,
            .size_adjustment = .none,
        });
    }

    const grid = try alloc.create(font.SharedGrid);
    errdefer alloc.destroy(grid);
    grid.* = try .init(alloc, .{ .collection = c });
    errdefer grid.deinit(alloc);

    var shaper = try font.Shaper.init(alloc, .{});
    errdefer shaper.deinit();

    const ptr = try alloc.create(ShaperRows);
    errdefer alloc.destroy(ptr);
    ptr.* = .{
        .opts = opts,
        .lib = lib,
        .grid = grid,
        .shaper = shaper,
        .terminal = try .init(alloc, .{
            .rows = opts.@"terminal-rows",
            .cols = opts.@"terminal-cols",
        }),
    };

    return ptr;
}

pub fn destroy(self: *ShaperRows, alloc: Allocator) void {
    self.state.deinit(alloc);
    self.terminal.deinit(alloc);
    self.shaper.deinit();
    self.grid.deinit(alloc);
    alloc.destroy(self.grid);
    self.lib.deinit();
    alloc.destroy(self);
}

pub fn benchmark(self: *ShaperRows) Benchmark {
    return .init(self, .{
        .stepFn = switch (self.opts.mode) {
            .runs => stepRuns,
            .shape => stepShape,
        },
        .setupFn = setup,
    });
}

fn setup(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ShaperRows = @ptrCast(@alignCast(ptr));
    const alloc = std.heap.c_allocator;

    self.terminal.fullReset();

    const data_f: std.fs.File = (options.dataFile(
        self.opts.data,
    ) catch |err| {
        log.warn("error opening data file err={}", .{err});
        return error.BenchmarkFailed;
    }) orelse return;

    var stream = self.terminal.vtStream();
    defer stream.deinit();

    var read_buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var f_reader = data_f.reader(&read_buf);
    const r = &f_reader.interface;

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached
        stream.nextSlice(buf[0..n]) catch |err| {
            log.warn("error processing data file chunk err={}", .{err});
            return error.BenchmarkFailed;
        };
    }

    self.state.update(alloc, &self.terminal) catch |err| {
        log.warn("error updating render state err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn stepRuns(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ShaperRows = @ptrCast(@alignCast(ptr));
    self.processRows(false) catch |err| {
        log.warn("error iterating runs err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn stepShape(ptr: *anyopaque) Benchmark.Error!void {
    const self: *ShaperRows = @ptrCast(@alignCast(ptr));
    self.processRows(true) catch |err| {
        log.warn("error shaping runs err={}", .{err});
        return error.BenchmarkFailed;
    };
}

fn processRows(self: *ShaperRows, shape: bool) !void {
    const alloc = std.heap.c_allocator;
    const rows = self.state.row_data.items(.cells);
    for (0..self.opts.iterations) |_| {
        for (rows) |cells| {
            var it = self.shaper.runIterator(.{
                .grid = self.grid,
                .cells = cells.slice(),
            });
            while (try it.next(alloc)) |run| {
                if (shape) {
                    std.mem.doNotOptimizeAway(try self.shaper.shape(run));
                } else {
                    std.mem.doNotOptimizeAway(run);
                }
            }
        }
    }
}

test ShaperRows {
    const testing = std.testing;
    const alloc = testing.allocator;

    const impl: *ShaperRows = try .create(alloc, .{});
    defer impl.destroy(alloc);

    const bench = impl.benchmark();
    _ = try bench.run(.once);
}
