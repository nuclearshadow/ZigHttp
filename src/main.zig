const std = @import("std");

const http = @import("http.zig");

fn root(_: http.Request) http.Response {
    return http.Response{
        .status = http.Status.OK,
        .body = "<html>Zig HTTP Server Test</html>",
    };
}

fn greet(req: http.Request) http.Response {
    var buf: [64]u8 = undefined;
    const name = if (req.params.get("name")) |name| name else "User";
    const body = std.fmt.bufPrint(&buf, "<html>Hello {s}!</html>", .{name}) catch "<html>Name too long</html>";
    return http.Response{
        .status = http.Status.OK,
        .body = body,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try http.Server(&[_]http.Route{
        .{ "/", http.MethodCallbacks{ .get = root } },
        .{ "/greet", http.MethodCallbacks{ .get = greet } },
    }).init(allocator, 6969);
    defer app.deinit();

    try app.listen();
}
