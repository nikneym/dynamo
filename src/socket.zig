const std = @import("std");
const os = std.os;
const net = std.net;
const mem = std.mem;
const linux = os.linux;
const EPOLL = linux.EPOLL;
const Queue = @import("queue.zig").Queue;
const Completion = @import("completion.zig");
const callback = @import("callback.zig");
const Loop = @import("backends/epoll.zig");

const Socket = @This();
fd: os.socket_t,
// write completions
write_q: Queue(Completion) = .{},
// read completions
read_q: Queue(Completion) = .{},

pub fn init() !Socket {
    const flags = os.SOCK.STREAM | os.SOCK.CLOEXEC | os.SOCK.NONBLOCK;
    const fd = try os.socket(os.AF.INET, flags, os.IPPROTO.TCP);
    errdefer os.closeSocket(fd);

    try os.setsockopt(fd, os.SOL.SOCKET, os.SO.REUSEADDR, &mem.toBytes(@as(c_int, 1)));

    return .{ .fd = fd };
}

pub fn create(allocator: mem.Allocator) !*Socket {
    const socket = try allocator.create(Socket);
    errdefer allocator.destroy(socket);
    socket.* = try Socket.init();

    return socket;
}

pub fn bind(self: Socket, address: net.Address) os.BindError!void {
    return os.bind(self.fd, &address.any, address.getOsSockLen());
}

pub fn listen(self: Socket, kernel_backlog: u31) os.ListenError!void {
    return os.listen(self.fd, kernel_backlog);
}

pub fn isReadable(_: Socket, event: linux.epoll_event) bool {
    return event.events & EPOLL.IN != 0;
}

pub fn isWritable(_: Socket, event: linux.epoll_event) bool {
    return event.events & EPOLL.OUT != 0;
}

pub fn isClosed(_: Socket, event: linux.epoll_event) bool {
    return event.events & EPOLL.RDHUP != 0;
}

pub fn connect(
    self: *Socket,
    c: *Completion,
    comptime T: type,
    userdata: *T,
    address: net.Address,
    comptime cb: callback.ConnectFn(T),
) !void {
    // we expect this to return error.Wouldblock.
    os.connect(self.fd, &address.any, address.getOsSockLen()) catch |e| switch (e) {
        error.WouldBlock => {},
        else => return e,
    };

    c.* = .{
        //.fd = self.fd,
        .userdata = userdata,
        .operation = .{
            .connect = .{
                .callback = comptime struct {
                    fn callback(
                        ud: *anyopaque,
                        loop: *Loop,
                        completion: *Completion,
                        socket: *Socket,
                        result: anyerror!void,
                    ) void {
                        return cb(
                            @ptrCast(*T, @alignCast(@alignOf(T), ud)),
                            loop,
                            completion,
                            socket,
                            result,
                        );
                    }
                }.callback,
            },
        },
    };

    // add the new operation to the queue.
    self.write_q.push(c);
}

pub fn write(
    self: *Socket,
    c: *Completion,
    comptime T: type,
    userdata: *T,
    bytes: []const u8,
    comptime cb: callback.WriteFn(T),
) !void {
    c.* = .{
        .userdata = userdata,
        .operation = .{
            .write = .{
                .bytes = bytes,
                .callback = comptime struct {
                    fn callback(
                        ud: *anyopaque,
                        loop: *Loop,
                        completion: *Completion,
                        socket: *Socket,
                        bytes1: []const u8,
                        result: anyerror!usize,
                    ) void {
                        return cb(
                            @ptrCast(*T, @alignCast(@alignOf(T), ud)),
                            loop,
                            completion,
                            socket,
                            bytes1,
                            result,
                        );
                    }
                }.callback,
            },
        },
    };

    self.write_q.push(c);
}

pub fn read(
    self: *Socket,
    c: *Completion,
    comptime T: type,
    userdata: *T,
    slice: []u8,
    comptime cb: callback.ReadFn(T),
) !void {
    c.* = .{
        .userdata = userdata,
        .operation = .{
            .read = .{
                .slice = slice,
                .callback = comptime struct {
                    fn callback(
                        ud: *anyopaque,
                        loop: *Loop,
                        completion: *Completion,
                        socket: *Socket,
                        slice1: []u8,
                        result: anyerror!usize,
                    ) void {
                        return cb(
                            @ptrCast(*T, @alignCast(@alignOf(T), ud)),
                            loop,
                            completion,
                            socket,
                            slice1,
                            result,
                        );
                    }
                }.callback,
            },
        },
    };

    self.read_q.push(c);
}

pub fn accept(
    self: *Socket,
    c: *Completion,
    comptime T: type,
    userdata: *T,
    comptime cb: callback.AcceptFn(T),
) !void {
    c.* = .{
        .userdata = userdata,
        .operation = .{
            .accept = .{
                .callback = comptime struct {
                    fn callback(
                        ud: *anyopaque,
                        loop: *Loop,
                        completion: *Completion,
                        socket: *Socket,
                        result: anyerror!*Socket,
                    ) void {
                        return cb(
                            @ptrCast(*T, @alignCast(@alignOf(T), ud)),
                            loop,
                            completion,
                            socket,
                            result,
                        );
                    }
                }.callback,
            },
        },
    };

    self.read_q.push(c);
}

pub fn writev(
    self: *Socket,
    c: *Completion,
    comptime T: type,
    userdata: *T,
    vectors: []const os.iovec_const,
    comptime cb: callback.WritevFn(T),
) !void {
    c.* = .{
        .userdata = userdata,
        .operation = .{
            .writev = .{
                .vectors = vectors,
                .callback = comptime struct {
                    fn callback(ud: *anyopaque, socket: *Socket, vec: []const os.iovec_const) void {
                        return cb(@ptrCast(*T, @alignCast(@alignOf(T), ud)), socket, vec);
                    }
                }.callback,
            },
        },
    };

    self.write_q.push(c);
}
