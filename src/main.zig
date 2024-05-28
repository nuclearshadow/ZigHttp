const std = @import("std");
const mem = std.mem;

const http = @import("http.zig");

fn helloWorld(_: http.Request) http.Response {
    return http.Response.OK("<html>Hello World!</html>");
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try http.Server(&[_]http.Route{
        .{ "/", helloWorld },
    }).init(allocator, "127.0.0.1", 6969);
    defer app.deinit();

    try app.listen();
}
