//! SIMD scoring for LibRaw's adaptive homogeneity-directed demosaicing tiles.
const std = @import("std");

const side = 512;
const Lab = [2][side][side][3]i16;
const Scores = [side][side][2]u8;
const Row = [2][3][side]i16;

// LibRaw supplies the halo and the exclusive end of the scoring region.
pub fn score(tile: c_int, row_end: c_int, col_end: c_int, lab: [*c]const i16, scores: [*c]u8) callconv(.c) c_int {
    if (tile != side or row_end < 2 or row_end > side - 2 or
        col_end < 2 or col_end > side - 2 or lab == null or scores == null) return 0;
    scoreTile(@ptrCast(lab), @ptrCast(scores), @intCast(row_end), @intCast(col_end));
    return 1;
}

fn scoreTile(lab: *const Lab, scores: *Scores, row_end: usize, col_end: usize) void {
    @memset(std.mem.asBytes(scores), 0);
    if (row_end == 2 or col_end == 2) return;

    // Keep three rows per direction. Repack only the newly arrived row.
    var rows: [3]Row = undefined;
    pack(&rows[0], lab, 1, col_end);
    pack(&rows[1], lab, 2, col_end);
    for (2..row_end) |y| {
        const above = &rows[(y - 2) % 3];
        const center = &rows[(y - 1) % 3];
        const below = &rows[y % 3];
        pack(below, lab, y + 1, col_end);
        var x: usize = 2;
        while (x + 8 <= col_end) : (x += 8) scoreBlock(8, above, center, below, x, &scores[y]);
        if (x + 4 <= col_end) {
            scoreBlock(4, above, center, below, x, &scores[y]);
            x += 4;
        }
        while (x < col_end) : (x += 1) scoreBlock(1, above, center, below, x, &scores[y]);
    }
}

fn pack(out: *Row, lab: *const Lab, y: usize, col_end: usize) void {
    inline for (0..2) |direction| {
        for (1..col_end + 1) |x| {
            const pixel = lab[direction][y][x];
            out[direction][0][x] = pixel[0];
            out[direction][1][x] = pixel[1];
            out[direction][2][x] = pixel[2];
        }
    }
}

fn load(comptime lanes: usize, plane: *const [side]i16, x: usize) @Vector(lanes, i32) {
    const values: @Vector(lanes, i16) = plane[x..][0..lanes].*;
    return @intCast(values);
}

fn scoreBlock(comptime lanes: usize, above: *const Row, center: *const Row, below: *const Row, x: usize, out: *[side][2]u8) void {
    const Distance = @Vector(lanes, u32);
    const Count = @Vector(lanes, u8);
    var light: [2][4]Distance = undefined;
    var chroma: [2][4]Distance = undefined;

    inline for (0..2) |direction| {
        const l = load(lanes, &center[direction][0], x);
        const a = load(lanes, &center[direction][1], x);
        const b = load(lanes, &center[direction][2], x);
        inline for (.{ center, center, above, below }, .{ x - 1, x + 1, x, x }, 0..) |row, column, i| {
            light[direction][i] = @abs(l - load(lanes, &row[direction][0], column));
            const da = a - load(lanes, &row[direction][1], column);
            const db = b - load(lanes, &row[direction][2], column);
            chroma[direction][i] = @bitCast(da *% da +% db *% db);
        }
    }

    const light_limit = @min(@max(light[0][0], light[0][1]), @max(light[1][2], light[1][3]));
    const chroma_limit = @min(@max(chroma[0][0], chroma[0][1]), @max(chroma[1][2], chroma[1][3]));
    var counts: [2]Count = undefined;
    inline for (0..2) |direction| {
        var sum: Count = @splat(0);
        inline for (0..4) |i| {
            const light_ok = @select(u8, light[direction][i] <= light_limit, @as(Count, @splat(1)), @as(Count, @splat(0)));
            const chroma_ok = @select(u8, chroma[direction][i] <= chroma_limit, @as(Count, @splat(1)), @as(Count, @splat(0)));
            sum += light_ok & chroma_ok;
        }
        counts[direction] = sum;
    }
    inline for (0..lanes) |i| out[x + i] = .{ counts[0][i], counts[1][i] };
}

test "AHD score agrees with scalar scoring on partial tiles and clears the border" {
    const lab = try std.testing.allocator.create(Lab);
    defer std.testing.allocator.destroy(lab);
    const actual = try std.testing.allocator.create(Scores);
    defer std.testing.allocator.destroy(actual);
    const expected = try std.testing.allocator.create(Scores);
    defer std.testing.allocator.destroy(expected);
    var prng = std.Random.DefaultPrng.init(173);
    prng.random().bytes(std.mem.asBytes(lab));

    for ([_]usize{ 2, 3, 11, 16, 17, 510 }) |col_end| {
        const row_end = 13;
        @memset(std.mem.asBytes(expected), 0);
        for (2..row_end) |y| {
            for (2..col_end) |x| {
                var light: [2][4]u32 = undefined;
                var chroma: [2][4]u32 = undefined;
                for (0..2) |direction| {
                    const center = lab[direction][y][x];
                    for ([_][2]usize{ .{ y, x - 1 }, .{ y, x + 1 }, .{ y - 1, x }, .{ y + 1, x } }, 0..) |neighbor, i| {
                        const adjacent = lab[direction][neighbor[0]][neighbor[1]];
                        light[direction][i] = @abs(@as(i32, center[0]) - adjacent[0]);
                        const da = @as(i64, center[1]) - adjacent[1];
                        const db = @as(i64, center[2]) - adjacent[2];
                        chroma[direction][i] = @truncate(@as(u64, @intCast(da * da + db * db)));
                    }
                }
                const l = @min(@max(light[0][0], light[0][1]), @max(light[1][2], light[1][3]));
                const c = @min(@max(chroma[0][0], chroma[0][1]), @max(chroma[1][2], chroma[1][3]));
                for (0..2) |direction| {
                    for (0..4) |i| {
                        if (light[direction][i] <= l and chroma[direction][i] <= c) expected[y][x][direction] += 1;
                    }
                }
            }
        }
        try std.testing.expectEqual(1, score(side, row_end, @intCast(col_end), @ptrCast(lab), @ptrCast(actual)));
        try std.testing.expectEqualSlices(u8, std.mem.asBytes(expected), std.mem.asBytes(actual));
    }
    try std.testing.expectEqual(0, score(side, 3, side, @ptrCast(lab), @ptrCast(actual)));
    try std.testing.expectEqual(0, score(256, 3, 3, @ptrCast(lab), @ptrCast(actual)));
}
