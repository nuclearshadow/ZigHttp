const std = @import("std");
const net = std.net;
const mem = std.mem;

pub const HttpError = error{
    InvalidRequest,
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    headers: std.StringArrayHashMap([]const u8),

    body: []const u8,

    fn parse(allocator: mem.Allocator, raw: []const u8) (mem.Allocator.Error || HttpError)!Request {
        var headers = std.StringArrayHashMap([]const u8).init(allocator);
        var lines = mem.splitSequence(u8, raw, "\r\n");
        const requestLine = lines.next() orelse return HttpError.InvalidRequest;
        var rlIt = mem.tokenizeScalar(u8, requestLine, ' ');
        const method = rlIt.next() orelse return HttpError.InvalidRequest;
        const uri = rlIt.next() orelse return HttpError.InvalidRequest;
        // ignoring the version

        while (lines.next()) |line| {
            if (mem.eql(u8, line, "")) break;
            var hIt = mem.splitScalar(u8, line, ':');
            const fieldName = hIt.next() orelse return HttpError.InvalidRequest;
            const filedValue = mem.trimLeft(u8, hIt.next() orelse return HttpError.InvalidRequest, " \t");
            try headers.put(fieldName, filedValue);
        }

        const body = lines.rest();

        return Request{
            .method = method,
            .uri = uri,
            .headers = headers,
            .body = body,
        };
    }
};

pub const Header = struct {
    // fields are anonymous so they can be initialized easily
    /// name
    []const u8,
    /// value
    []const u8,
};

pub const Response = struct {
    statusCode: u16,
    reason: []const u8,
    headers: []const Header = &[_]Header{},

    body: []const u8 = "",

    fn serialize(self: Response, allocator: mem.Allocator) ![]u8 {
        const statusLine = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\n", .{
            self.statusCode,
            self.reason,
        });
        defer allocator.free(statusLine);

        var headers: [][]const u8 = try allocator.alloc([]const u8, self.headers.len);
        defer allocator.free(headers);

        for (self.headers, 0..) |header, i| {
            headers[i] = try std.fmt.allocPrint(allocator, "{s}: {s}\r\n", .{ header.@"0", header.@"1" });
        }
        defer for (headers) |header| allocator.free(header);

        const headersRaw = try mem.concat(allocator, u8, headers);
        defer allocator.free(headersRaw);

        const body = try std.fmt.allocPrint(allocator, "\r\n{s}", .{self.body});
        defer allocator.free(body);

        return try mem.concat(allocator, u8, &[_][]const u8{
            statusLine,
            headersRaw,
            body,
        });
    }

    pub fn OK(body: []const u8) Response {
        return Response{
            .statusCode = 200,
            .reason = "OK",
            .body = body,
        };
    }
    pub fn NotFound(body: []const u8) Response {
        return Response{
            .statusCode = 404,
            .reason = "Not Found",
            .body = body,
        };
    }
    pub fn InternalServerError(body: []const u8) Response {
        return Response{
            .statusCode = 500,
            .reason = "Internal Server Error",
            .body = body,
        };
    }
};

pub const Route = struct {
    /// path
    []const u8,
    /// callback function
    *const fn (Request) Response,
};

pub fn Server(handlers: []const Route) type {
    const Routes = std.ComptimeStringMap(*const fn (Request) Response, handlers);
    return struct {
        host: []const u8,
        port: u16,

        server: net.Server = undefined,

        allocator: mem.Allocator,

        pub fn init(allocator: mem.Allocator, host: []const u8, port: u16) !@This() {
            const loopback = try net.Ip4Address.parse(host, port);
            const localhost = net.Address{ .in = loopback };
            const server = try localhost.listen(.{
                .reuse_port = true,
            });
            return @This(){
                .host = host,
                .port = port,
                .server = server,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.server.deinit();
        }

        pub fn listen(self: *@This()) !void {
            std.debug.print("Server Listening on {}\n", .{self.port});

            var readBuffer: [1024]u8 = undefined;
            while (self.server.accept()) |con| {
                std.debug.print("Connection received from {}\n", .{con.address});
                const bytesRead = try con.stream.reader().read(&readBuffer);
                const reqRaw = readBuffer[0..bytesRead];

                std.debug.print("Recieved Request:\n{s}\n", .{reqRaw});

                var req = try Request.parse(self.allocator, reqRaw);
                defer req.headers.deinit();

                const res = if (Routes.get(req.path)) |handler| handler(req) else Response.NotFound("");

                const resSerialized = try res.serialize(self.allocator);
                defer self.allocator.free(resSerialized);

                std.debug.print("Response: {s}\n", .{resSerialized});
                _ = try con.stream.write(resSerialized);
                con.stream.close();
            } else |e| {
                return e;
            }
        }
    };
}

test "Resquest Parsing" {
    const reqRaw =
        "GET / HTTP/1.1\r\n" ++
        "\r\n";

    var req = try Request.parse(std.testing.allocator, reqRaw);
    defer req.headers.deinit();

    try std.testing.expect(mem.eql(u8, req.method, "GET"));
    try std.testing.expect(mem.eql(u8, req.path, "/"));
    // std.debug.print("\nBody: {s}\n", .{req.body});
    try std.testing.expect(mem.eql(u8, req.body, ""));
}

test "Response Serialization" {
    const res = Response{
        .statusCode = 200,
        .reason = "OK",
        .headers = &[_]Header{
            .{ "Server", "ZigHttp" },
            .{ "Content-Type", "text/html" },
        },
        .body = "<html>Hello World!</html>",
    };
    const expected =
        "HTTP/1.1 200 OK\r\n" ++
        "Server: ZigHttp\r\n" ++
        "Content-Type: text/html\r\n" ++
        "\r\n" ++
        "<html>Hello World!</html>";

    const actual = try res.serialize(std.testing.allocator);
    defer std.testing.allocator.free(actual);

    std.debug.print("Actual: {s}\n", .{actual});

    try std.testing.expect(mem.eql(u8, actual, expected));
}