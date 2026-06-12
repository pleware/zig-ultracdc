const std = @import("std");
const ultracdc = @import("ultracdc");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Polyval = std.crypto.onetimeauth.Polyval;

const Hash = u128;

const FileStats = struct {
    path: []const u8,
    chunks: usize,
    bytes: usize,
};

const ChunkingStats = struct {
    total_chunks: usize = 0,
    unique_chunks: usize = 0,
    total_bytes: usize = 0,
    min_chunk_size: usize = std.math.maxInt(usize),
    max_chunk_size: usize = 0,
    file_stats: std.ArrayList(FileStats) = .empty,

    fn deinit(self: *ChunkingStats, allocator: Allocator) void {
        for (self.file_stats.items) |stat| {
            allocator.free(stat.path);
        }
        self.file_stats.deinit(allocator);
    }
};

fn printHelp(program_name: []const u8, writer: *Io.Writer) !void {
    try writer.print(
        \\Usage: {s} [options] <file1> [file2] [file3] ...
        \\
        \\Options:
        \\  --min-size <bytes>     Minimum chunk size (default: 8192)
        \\  --normal-size <bytes>  Normal chunk size (default: 65536)
        \\  --max-size <bytes>     Maximum chunk size (default: 131072)
        \\  --help, -h             Show this help message
        \\
        \\Description:
        \\  Chunks files using UltraCDC and computes hashes to measure
        \\  deduplication potential. Displays total chunks and unique chunks to estimate
        \\  compression ratio.
        \\
        \\Example:
        \\  {s} file1.bin file2.bin
        \\  {s} --min-size 4096 --max-size 131072 large_file.dat
        \\
    , .{ program_name, program_name, program_name });
}

fn parseSizeOption(args: *std.process.Args.Iterator, option: []const u8, stderr: *Io.Writer) !usize {
    const value = args.next() orelse {
        try stderr.print("Error: Option {s} requires a value\n", .{option});
        return error.MissingValue;
    };
    return std.fmt.parseInt(usize, value, 10);
}

fn computeHash(key: *const [Polyval.key_length]u8, data: []const u8) Hash {
    var out: [Polyval.mac_length]u8 = undefined;
    Polyval.create(&out, data, key);
    return std.mem.readInt(Hash, &out, .little);
}

fn processFile(
    allocator: Allocator,
    io: Io,
    file_path: []const u8,
    opts: ultracdc.ChunkerOptions,
    key: *const [Polyval.key_length]u8,
    hash_set: *std.AutoHashMapUnmanaged(Hash, void),
    stats: *ChunkingStats,
    writer: *Io.Writer,
) !void {
    const data = try Io.Dir.cwd().readFileAlloc(io, file_path, allocator, .limited(10 * 1024 * 1024 * 1024));
    defer allocator.free(data);

    if (data.len == 0) {
        try writer.print("Warning: Skipping empty file: {s}\n", .{file_path});
        return;
    }

    var file_chunks: usize = 0;
    var offset: usize = 0;

    while (offset < data.len) {
        const remaining = data.len - offset;
        const cutpoint = ultracdc.UltraCDC.find(opts, data[offset..], remaining);

        const hash = computeHash(key, data[offset..][0..cutpoint]);
        const gop = try hash_set.getOrPut(allocator, hash);
        if (!gop.found_existing) {
            stats.unique_chunks += 1;
        }

        stats.total_chunks += 1;
        file_chunks += 1;
        stats.min_chunk_size = @min(stats.min_chunk_size, cutpoint);
        stats.max_chunk_size = @max(stats.max_chunk_size, cutpoint);

        offset += cutpoint;
    }

    stats.total_bytes += data.len;

    const path_copy = try allocator.dupe(u8, file_path);
    try stats.file_stats.append(allocator, .{
        .path = path_copy,
        .chunks = file_chunks,
        .bytes = data.len,
    });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_writer = Io.File.stdout().writer(io, &.{});
    const stdout = &stdout_writer.interface;

    var stderr_writer = Io.File.stderr().writer(io, &.{});
    const stderr = &stderr_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();

    const program_name = args.next() orelse "ultracdc";

    var opts: ultracdc.ChunkerOptions = .{};
    var file_paths: std.ArrayList([]const u8) = .empty;
    defer file_paths.deinit(allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp(program_name, stdout);
            return;
        } else if (std.mem.eql(u8, arg, "--min-size")) {
            opts.min_size = try parseSizeOption(&args, arg, stderr);
        } else if (std.mem.eql(u8, arg, "--normal-size")) {
            opts.normal_size = try parseSizeOption(&args, arg, stderr);
        } else if (std.mem.eql(u8, arg, "--max-size")) {
            opts.max_size = try parseSizeOption(&args, arg, stderr);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            try stderr.print("Error: Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        } else {
            try file_paths.append(allocator, arg);
        }
    }

    if (file_paths.items.len == 0) {
        try stderr.writeAll("Error: No input files specified\n\n");
        try printHelp(program_name, stderr);
        return error.NoInputFiles;
    }

    try stdout.writeAll(
        \\UltraCDC Deduplication Analyzer
        \\===============================
        \\
        \\Chunker options:
        \\
    );
    try stdout.print(
        \\  Min size:    {d} bytes
        \\  Normal size: {d} bytes
        \\  Max size:    {d} bytes
        \\
        \\
    , .{ opts.min_size, opts.normal_size, opts.max_size });

    var key: [Polyval.key_length]u8 = undefined;
    const rand_source = std.Random.IoSource{ .io = io };
    rand_source.interface().bytes(&key);

    var hash_set: std.AutoHashMapUnmanaged(Hash, void) = .empty;
    defer hash_set.deinit(allocator);

    var stats: ChunkingStats = .{};
    defer stats.deinit(allocator);

    try stdout.print("Processing {d} file(s)...\n\n", .{file_paths.items.len});

    for (file_paths.items) |file_path| {
        try stdout.print("  Processing: {s}\n", .{file_path});
        processFile(allocator, io, file_path, opts, &key, &hash_set, &stats, stderr) catch |err| {
            try stderr.print("  Error processing {s}: {t}\n", .{ file_path, err });
            continue;
        };
    }

    try stdout.writeAll(
        \\
        \\Results:
        \\========
        \\
        \\
    );

    try stdout.print("  Total chunks:        {d}\n", .{stats.total_chunks});
    try stdout.print("  Unique chunks:       {d}\n", .{stats.unique_chunks});

    const duplicate_chunks = stats.total_chunks - stats.unique_chunks;
    try stdout.print("  Duplicate chunks:    {d}", .{duplicate_chunks});

    if (stats.total_chunks > 0) {
        const dup_pct = @as(f64, @floatFromInt(duplicate_chunks)) / @as(f64, @floatFromInt(stats.total_chunks)) * 100.0;
        try stdout.print(" ({d:.1}%)\n", .{dup_pct});
    } else {
        try stdout.writeAll("\n");
    }

    if (stats.unique_chunks > 0) {
        const ratio = @as(f64, @floatFromInt(stats.total_chunks)) / @as(f64, @floatFromInt(stats.unique_chunks));
        try stdout.print("  Deduplication ratio: {d:.2}x\n", .{ratio});
    }

    try stdout.print("  Total data:          {Bi:.2}\n", .{stats.total_bytes});

    if (stats.total_chunks > 0) {
        const avg_chunk = stats.total_bytes / stats.total_chunks;
        try stdout.print("  Average chunk:       {Bi:.2}\n", .{avg_chunk});

        if (stats.min_chunk_size != std.math.maxInt(usize)) {
            try stdout.print("  Min chunk:           {Bi:.2}\n", .{stats.min_chunk_size});
        }

        try stdout.print("  Max chunk:           {Bi:.2}\n", .{stats.max_chunk_size});
    }

    if (stats.file_stats.items.len > 1) {
        try stdout.writeAll("\nPer-file breakdown:\n");
        for (stats.file_stats.items) |file_stat| {
            try stdout.print("  {s}: {d} chunks, {Bi:.2}\n", .{
                file_stat.path,
                file_stat.chunks,
                file_stat.bytes,
            });
        }
    }

    try stdout.writeAll("\n");
}
