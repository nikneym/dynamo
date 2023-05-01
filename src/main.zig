const std = @import("std");
const net = std.net;
const Loop = @import("backends/epoll.zig");
const Socket = Loop.Socket;

fn onReadFn(loop: *Loop, socket: *Socket, buffer: []u8, length: usize) void {
    std.debug.print("{s}", .{buffer[0..length]});

    socket.read(
        loop.getCompletion() catch unreachable,
        Loop,
        loop,
        buffer[0..],
        onReadFn,
    ) catch unreachable;

    socket.write(
        loop.getCompletion() catch unreachable,
        Loop,
        loop,
        buffer[0..length],
        onWriteFn,
    ) catch unreachable;
}

fn onWriteFn(loop: *Loop, socket: *Socket, bytes: []const u8) void {
    _ = bytes;
    _ = socket;
    _ = loop;
}

fn onAcceptFn(loop: *Loop, socket: *Socket, incoming: *Socket) void {
    //std.debug.print("{}\n", .{incoming});
    std.debug.print("accepted new socket\n", .{});

    incoming.read(
        loop.getCompletion() catch unreachable,
        Loop,
        loop,
        loop.allocator.alloc(u8, 1024) catch unreachable,
        onReadFn,
    ) catch unreachable;

    socket.accept(
        loop.getCompletion() catch unreachable,
        Loop,
        loop,
        onAcceptFn,
    ) catch unreachable;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var loop = try Loop.init(allocator, 16);
    defer loop.deinit();

    std.debug.print("completion size: {}\n", .{@sizeOf(Loop.Completion)});
    std.debug.print("socket size: {}\n", .{@sizeOf(Loop.Socket)});

    var socket = try Socket.init();
    try loop.register(&socket);

    try socket.bind(try net.Address.parseIp("127.0.0.1", 8080));
    try socket.listen(128);

    try socket.accept(
        try loop.getCompletion(),
        Loop,
        &loop,
        onAcceptFn,
    );

    try loop.run();
}
