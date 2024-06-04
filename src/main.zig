const std = @import("std");
const mem = std.mem;

const http = @import("http.zig");

fn root(_: mem.Allocator, _: http.Request) !http.Response {
    return http.Response{
        .status = http.Status.OK,
        .body = "<html>Zig HTTP Server Test</html>",
    };
}

fn greet(alloc: mem.Allocator, req: http.Request) !http.Response {
    const name = if (req.params.get("name")) |name| name else "User";
    const body = try std.fmt.allocPrint(alloc, "<html>Hello {s}!</html>", .{name});
    std.debug.print("{s}\n", .{body});
    return http.Response{
        .status = http.Status.OK,
        .body = body,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try http.Server(&.{
        .{ "/", .{ .get = root } },
        .{ "/greet", .{ .get = greet } },
    }).init(allocator, 6969);
    defer app.deinit();

    try app.setStaticDir("static");

    try app.listen();
}
