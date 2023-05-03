const std = @import("std");
const net = std.net;
const os = std.os;
const dynamo = @import("main.zig");

fn onReadFn(loop: *dynamo.Loop, socket: *dynamo.Socket, buffer: []u8, length: usize) void {
    _ = socket;
    _ = loop;
    std.debug.print("{s}", .{buffer[0..length]});
}

fn onWriteFn(loop: *dynamo.Loop, socket: *dynamo.Socket, bytes: []const u8) void {
    _ = socket;
    _ = loop;
    _ = bytes;
}

fn onConnectFn(loop: *dynamo.Loop, socket: *dynamo.Socket) void {
    _ = socket;
    _ = loop;
    std.debug.print("connected\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try dynamo.Loop.init(allocator, 16);
    defer loop.deinit();

    std.debug.print("completion size: {}\n", .{@sizeOf(dynamo.Completion)});
    std.debug.print("socket size: {}\n", .{@sizeOf(dynamo.Socket)});

    var socket = try dynamo.Socket.init();
    try loop.register(&socket);

    try socket.connect(
        try loop.getCompletion(),
        dynamo.Loop,
        &loop,
        try net.Address.parseIp("216.58.214.142", 80),
        onConnectFn,
    );

    socket.write(
        loop.getCompletion() catch unreachable,
        dynamo.Loop,
        &loop,
        "GET / HTTP/1.1\r\n\r\n",
        onWriteFn,
    ) catch unreachable;

    socket.read(
        loop.getCompletion() catch unreachable,
        dynamo.Loop,
        &loop,
        loop.allocator.alloc(u8, 4096) catch unreachable,
        onReadFn,
    ) catch unreachable;

    //try socket.bind(try net.Address.parseIp("127.0.0.1", 8080));
    //try socket.listen(128);
    //try socket.accept(
    //    try loop.getCompletion(),
    //    Loop,
    //    &loop,
    //    onAcceptFn,
    //);

    try loop.run();
}
