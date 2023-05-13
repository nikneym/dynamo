const std = @import("std");
const net = std.net;
const os = std.os;
const dynamo = @import("main.zig");

fn onReadFn(
    userdata: *i32,
    loop: *dynamo.Loop,
    completion: *dynamo.Completion,
    socket: *dynamo.Socket,
    buffer: []u8,
    result: anyerror!usize,
) void {
    _ = userdata;
    _ = completion;
    _ = socket;
    _ = loop;
    const length = result catch |e| {
        std.debug.print("{}\n", .{e});
        return;
    };

    std.debug.print("{s}", .{buffer[0..length]});
}

fn onWriteFn(
    userdata: *i32,
    loop: *dynamo.Loop,
    completion: *dynamo.Completion,
    socket: *dynamo.Socket,
    bytes: []const u8,
    result: anyerror!usize,
) void {
    std.debug.print("write complete!\n", .{});
    _ = completion;
    _ = userdata;
    _ = socket;
    _ = loop;
    _ = bytes;
    const len = result catch |e| {
        std.debug.print("{}\n", .{e});
        return;
    };
    _ = len;
}

fn onConnectFn(
    userdata: *dynamo.Loop,
    loop: *dynamo.Loop,
    completion: *dynamo.Completion,
    socket: *dynamo.Socket,
    result: anyerror!void,
) void {
    _ = socket;
    _ = userdata;

    result catch |e| {
        std.debug.print("{}\n", .{e});
        loop.freeCompletion(completion);
        return;
    };

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

    var num: i32 = 7;

    try socket.write(
        try loop.getCompletion(),
        i32,
        &num,
        "GET / HTTP/1.1\r\n\r\n",
        onWriteFn,
    );

    try socket.read(
        try loop.getCompletion(),
        i32,
        &num,
        try allocator.alloc(u8, 1024),
        onReadFn,
    );

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
