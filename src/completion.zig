const std = @import("std");
const os = std.os;
const net = std.net;
const mem = std.mem;
const callback = @import("callback.zig");
const Socket = @import("socket.zig");
const Loop = @import("backends/epoll.zig");
const Queue = @import("queue.zig").Queue;

const Completion = @This();
userdata: *anyopaque,
operation: Operation,
next: ?*Completion = null,

pub const Operation = union(enum) {
    none: struct {},

    // sockets specific
    connect: struct {
        callback: callback.ConnectFn(anyopaque),
    },

    accept: struct {
        callback: callback.AcceptFn(anyopaque),
    },

    // linear I/O
    write: struct {
        bytes: []const u8,
        callback: callback.WriteFn(anyopaque),
    },

    read: struct {
        slice: []u8,
        callback: callback.ReadFn(anyopaque),
    },

    // TODO: implement corresponding perform functions
    // scatter/gather (vectored) I/O
    writev: struct {
        vectors: [*]os.iovec_const,
        callback: callback.WritevFn(anyopaque),
    },

    readv: struct {
        vectors: []os.iovec,
        //callback: callback.ReadFn(anyopaque),
    },
};

pub fn perform(self: *Completion, allocator: mem.Allocator, socket: *Socket, loop: *Loop) !void {
    switch (self.operation) {
        .connect => |op| {
            // run the completion callback
            op.callback(
                self.userdata,
                loop,
                self,
                socket,
                os.getsockoptError(socket.fd) catch |e| e,
            );

            // FIXME: epoll notifies us that it's still writable here
            // so, it should be okay to continue doing write operations.
            // this is also a must since EPOLLET only notifies us when
            // fd status is changed.
            var queue: Queue(Completion) = socket.write_q;
            socket.write_q = .{};

            while (queue.pop()) |c| {
                try c.perform(allocator, socket, loop);
            }
        },
        .write => |op| {
            // write 'till we got blocked
            var pos: usize = 0;
            while (pos < op.bytes.len) {
                const len = os.write(socket.fd, op.bytes[pos..]) catch |e| switch (e) {
                    // put back unsubmitted events
                    error.WouldBlock => {
                        if (self.next) |next| socket.write_q.push(next);
                        break;
                    },
                    else => {
                        op.callback(self.userdata, loop, self, socket, op.bytes, e);
                        return;
                    },
                };

                pos += len;
            }

            // run the completion callback
            op.callback(self.userdata, loop, self, socket, op.bytes, pos);
        },
        .read => |op| {
            // read 'till we got blocked
            var pos: usize = 0;
            while (pos < op.slice.len) {
                const len = os.read(socket.fd, op.slice[pos..]) catch |e| switch (e) {
                    // put back unsubmitted events
                    error.WouldBlock => {
                        if (self.next) |next| socket.read_q.push(next);
                        break;
                    },
                    // notify the caller with the error
                    else => {
                        op.callback(self.userdata, loop, self, socket, op.slice, e);
                        return;
                    },
                };

                pos += len;
            }

            // call without errors
            op.callback(self.userdata, loop, self, socket, op.slice, pos);
        },
        .accept => |op| {
            // see if we can accept the incoming connection
            var addr: net.Address = undefined;
            var addr_len: os.socklen_t = @sizeOf(net.Address);

            const fd = os.accept(
                socket.fd,
                &addr.any,
                &addr_len,
                os.SOCK.CLOEXEC | os.SOCK.NONBLOCK,
            ) catch |e| switch (e) {
                // FIXME: I'm not sure if this is necessary
                //error.WouldBlock => {
                //    socket.read_q.push(self);
                //    return;
                //},
                else => {
                    op.callback(self.userdata, loop, self, socket, e);
                    return;
                },
            };

            // FIXME: use a pool for these sockets?
            // allocate a new Socket for incoming connection
            const incoming = loop.allocator.create(Socket) catch |e| {
                op.callback(self.userdata, loop, self, socket, e);
                return;
            };
            errdefer loop.allocator.destroy(incoming);
            incoming.* = .{ .fd = fd };
            // register the new socket to our loop
            loop.register(incoming) catch |e| {
                op.callback(self.userdata, loop, self, socket, e);
                return;
            };

            op.callback(self.userdata, loop, self, socket, incoming);
        },

        else => @panic("not implemented yet"),
    }
}
