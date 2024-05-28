const std = @import("std");
const mem = std.mem;

const http = @import("http.zig");

fn root(_: http.Request) http.Response {
    return http.Response{
        .status = http.Status.OK,
        .body = "<html>Zig HTTP Server Test</html>",
    };
}

fn greet(_: http.Request) http.Response {
    return http.Response{
        .status = http.Status.OK,
        .body = "<html>Hello User!</html>",
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try http.Server(&[_]http.Route{
        .{ "/", root },
        .{ "/greet", greet },
    }).init(allocator, "127.0.0.1", 6969);
    defer app.deinit();

    try app.listen();
}
