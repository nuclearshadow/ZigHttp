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
    params: std.StringArrayHashMap([]const u8),
    body: []const u8,

    fn parse(allocator: mem.Allocator, raw: []const u8) (mem.Allocator.Error || HttpError)!Request {
        var headers = std.StringArrayHashMap([]const u8).init(allocator);
        var params = std.StringArrayHashMap([]const u8).init(allocator);
        var lines = mem.splitSequence(u8, raw, "\r\n");

        const requestLine = lines.next() orelse return HttpError.InvalidRequest;
        var rlIt = mem.tokenizeScalar(u8, requestLine, ' ');
        const method = rlIt.next() orelse return HttpError.InvalidRequest;

        const uri = rlIt.next() orelse return HttpError.InvalidRequest;
        var uriIt = mem.splitScalar(u8, uri, '?');
        const path = uriIt.next().?;

        const paramStr = uriIt.next();
        if (paramStr) |p| {
            var paramsIt = mem.splitScalar(u8, p, '&');
            while (paramsIt.next()) |param| {
                var pIt = mem.splitScalar(u8, param, '=');
                const name = pIt.next() orelse return HttpError.InvalidRequest;
                const value = pIt.next() orelse return HttpError.InvalidRequest;
                try params.put(name, value);
            }
        }

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
            .path = path,
            .headers = headers,
            .params = params,
            .body = body,
        };
    }
};

pub const Status = struct {
    code: u16,
    reason: []const u8,

    pub const OK = Status{
        .code = 200,
        .reason = "OK",
    };

    pub const NotFound = Status{
        .code = 404,
        .reason = "Not Found",
    };

    pub const InternalServerError = Status{
        .code = 500,
        .reason = "Internal Server Error",
    };
};

pub const Header = struct {
    // fields are anonymous so they can be initialized easily
    /// name
    []const u8,
    /// value
    []const u8,
};

pub const Response = struct {
    status: Status,
    headers: []const Header = &[_]Header{},

    body: []const u8 = "",

    fn serialize(self: Response, allocator: mem.Allocator) ![]u8 {
        const statusLine = try std.fmt.allocPrint(allocator, "HTTP/1.1 {d} {s}\r\n", .{
            self.status.code,
            self.status.reason,
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
};

pub const MethodCallbacks = struct {
    get: ?*const fn (Request) Response = null,
    post: ?*const fn (Request) Response = null,
    put: ?*const fn (Request) Response = null,
    delete: ?*const fn (Request) Response = null,
    // options: ?*const fn (Request) Response = null,
    // trace: ?*const fn (Request) Response = null,
    // connect: ?*const fn (Request) Response = null,
};

pub const Route = struct {
    /// path
    []const u8,
    MethodCallbacks,
};

/// The routes are evaluated at compile time so they are taken as a paramater to the type rather than to the instance
pub fn Server(handlers: []const Route) type {
    const Routes = std.ComptimeStringMap(MethodCallbacks, handlers);
    return struct {
        port: u16,

        server: net.Server = undefined,

        allocator: mem.Allocator,

        pub fn init(allocator: mem.Allocator, port: u16) !@This() {
            const loopback = try net.Ip4Address.parse("127.0.0.1", port);
            const localhost = net.Address{ .in = loopback };
            const server = try localhost.listen(.{
                .reuse_port = true,
            });
            return @This(){
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

                std.debug.print("--Recieved Request--" ++ "-" ** 20 ++ "\n{s}\n" ++ "-" ** 40 ++ "\n", .{reqRaw});

                var req = try Request.parse(self.allocator, reqRaw);
                defer req.headers.deinit();

                var methodUpper: [8]u8 = undefined;
                const res = if (Routes.get(req.path)) |methods| res: {
                    inline for (@typeInfo(MethodCallbacks).Struct.fields) |field| {
                        if (mem.eql(u8, std.ascii.upperString(&methodUpper, field.name), req.method)) {
                            break :res if (@field(methods, field.name)) |method|
                                method(req)
                            else
                                Response{ .status = Status{ .code = 405, .reason = "Method Not Allowed" } };
                        }
                        break :res Response{ .status = Status{ .code = 405, .reason = "Method Not Allowed" } };
                    }
                } else Response{ .status = Status.NotFound };

                const resSerialized = try res.serialize(self.allocator);
                defer self.allocator.free(resSerialized);

                std.debug.print("--Response--" ++ "-" ** 28 ++ "\n{s}\n" ++ "-" ** 40 ++ "\n", .{resSerialized});
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
        .status = Status.OK,
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
