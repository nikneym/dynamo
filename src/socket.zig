const std = @import("std");
const os = std.os;
const net = std.net;
const mem = std.mem;
const linux = os.linux;
const EPOLL = linux.EPOLL;
const Queue = @import("queue.zig").Queue;
const Completion = @import("completion.zig");
const callback = @import("callback.zig");

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
                    fn callback(ud: *anyopaque, socket: *Socket) void {
                        return cb(@ptrCast(*T, @alignCast(@alignOf(T), ud)), socket);
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
        //.fd = self.fd,
        .userdata = userdata,
        .operation = .{
            .write = .{
                .bytes = bytes,
                .callback = comptime struct {
                    fn callback(ud: *anyopaque, socket: *Socket, bytes1: []const u8) void {
                        return cb(@ptrCast(*T, @alignCast(@alignOf(T), ud)), socket, bytes1);
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
        //.fd = self.fd,
        .userdata = userdata,
        .operation = .{
            .read = .{
                .slice = slice,
                .callback = comptime struct {
                    fn callback(ud: *anyopaque, socket: *Socket, slice1: []u8, length: usize) void {
                        return cb(@ptrCast(*T, @alignCast(@alignOf(T), ud)), socket, slice1, length);
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
                    fn callback(ud: *anyopaque, socket: *Socket, incoming: *Socket) void {
                        return cb(@ptrCast(*T, @alignCast(@alignOf(T), ud)), socket, incoming);
                    }
                }.callback,
            },
        },
    };

    self.read_q.push(c);
}
