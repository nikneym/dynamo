const std = @import("std");
const os = std.os;
const net = std.net;
const mem = std.mem;
const linux = os.linux;
const EPOLL = linux.EPOLL;
const Queue = @import("../queue.zig").Queue;

const Loop = @This();
fd: os.fd_t,
allocator: mem.Allocator,
completion_pool: CompletionPool,

fn ReadFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        socket: *Socket,
        slice: []u8,
        length: usize,
    ) void;
}

fn ConnectFn(comptime T: type) type {
    return *const fn (userdata: *align(@alignOf(T)) T, socket: *Socket) void;
}

fn WriteFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        socket: *Socket,
        bytes: []const u8,
    ) void;
}

fn AcceptFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        socket: *Socket,
        incoming: *Socket,
    ) void;
}

pub const Socket = struct {
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

    fn isReadable(_: Socket, event: linux.epoll_event) bool {
        return event.events & EPOLL.IN != 0;
    }

    fn isWritable(_: Socket, event: linux.epoll_event) bool {
        return event.events & EPOLL.OUT != 0;
    }

    fn isClosed(_: Socket, event: linux.epoll_event) bool {
        return event.events & EPOLL.RDHUP != 0;
    }

    pub fn connect(
        self: *Socket,
        c: *Completion,
        comptime T: type,
        userdata: *T,
        address: net.Address,
        comptime cb: ConnectFn(T),
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
        comptime cb: WriteFn(T),
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
        comptime cb: ReadFn(T),
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
        comptime cb: AcceptFn(T),
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
};

const CompletionPool = std.heap.MemoryPool(Completion);
pub const Completion = struct {
    //fd: os.socket_t,
    userdata: *anyopaque,
    operation: Operation,
    next: ?*Completion = null,

    pub const Operation = union(enum) {
        none: struct {},

        connect: struct {
            callback: ConnectFn(anyopaque),
        },

        accept: struct {
            callback: AcceptFn(anyopaque),
        },

        write: struct {
            bytes: []const u8,
            callback: WriteFn(anyopaque),
        },

        read: struct {
            slice: []u8,
            callback: ReadFn(anyopaque),
        },
    };

    pub fn perform(self: *Completion, socket: *Socket, loop: *Loop) !void {
        switch (self.operation) {
            .connect => |op| {
                // TODO: report errors to the completion callback
                try os.getsockoptError(socket.fd);
                // run the completion callback
                op.callback(self.userdata, socket);
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
                        else => return e,
                    };
                    pos += len;
                }

                // run the completion callback
                op.callback(self.userdata, socket, op.bytes);
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
                        else => return e,
                    };

                    pos += len;
                }

                op.callback(self.userdata, socket, op.slice, pos);
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
                    error.WouldBlock => {
                        socket.read_q.push(self);
                        return;
                    },
                    else => return e,
                };

                // FIXME: use a pool for these sockets?
                // allocate a new Socket for incoming connection
                const incoming = try loop.allocator.create(Socket);
                errdefer loop.allocator.destroy(incoming);
                incoming.* = .{ .fd = fd };
                // register the new socket to our loop
                try loop.register(incoming);

                op.callback(self.userdata, socket, incoming);
            },

            else => @panic("not implemented yet"),
        }
    }
};

/// Creates a new event Loop.
pub fn init(allocator: mem.Allocator, initial_completion_size: usize) !Loop {
    const fd = try os.epoll_create1(EPOLL.CLOEXEC);
    errdefer os.close(fd);
    const completion_pool = try CompletionPool.initPreheated(allocator, initial_completion_size);
    errdefer completion_pool.deinit();

    return .{
        .fd = fd,
        .allocator = allocator,
        .completion_pool = completion_pool,
    };
}

/// Releases the event loop and it's resources.
pub fn deinit(self: *Loop) void {
    os.close(self.fd);
    self.completion_pool.deinit();
    self.* = undefined;
}

pub fn register(self: Loop, socket: *const Socket) !void {
    const event = &linux.epoll_event{
        // EPOLLRDHUP is needed to check if socket has closed
        .events = EPOLL.IN | EPOLL.OUT | EPOLL.RDHUP | EPOLL.ET,
        .data = .{ .ptr = @ptrToInt(socket) },
    };

    return os.epoll_ctl(self.fd, EPOLL.CTL_ADD, socket.fd, event) catch |e| switch (e) {
        // unlikely but still
        error.FileDescriptorAlreadyPresentInSet => os.epoll_ctl(self.fd, EPOLL.CTL_MOD, socket.fd, event),
        // report any other error
        else => e,
    };
}

pub fn unregister(self: Loop, socket: Socket) !void {
    return os.epoll_ctl(self.fd, EPOLL.CTL_DEL, socket.fd, null);
}

pub fn getCompletion(self: *Loop) !*Completion {
    return self.completion_pool.create();
}

pub fn freeCompletion(self: *Loop, c: *Completion) void {
    return self.completion_pool.destroy(c);
}

pub fn run(self: *Loop) !void {
    var events: [1024]linux.epoll_event = undefined;
    while (true) {
        const num_events = os.epoll_wait(self.fd, &events, 500);
        std.debug.print("{}\n", .{num_events});
        //std.debug.print("{any}\n", .{events[0..num_events]});

        for (events[0..num_events]) |event| {
            const socket: *Socket = @intToPtr(*Socket, event.data.ptr);

            // FIXME: this should be checked in completion operations
            // let's first check if socket is just closed
            if (socket.isClosed(event)) {
                try self.unregister(socket.*);
                os.close(socket.fd);
                continue;
            }

            var queue: Queue(Completion) = undefined;

            if (socket.isReadable(event)) {
                // get a copy of our queue and reset the original one
                queue = socket.read_q;
                socket.read_q = .{};

                while (queue.pop()) |c| {
                    try c.perform(socket, self);
                }
            }

            if (socket.isWritable(event)) {
                queue = socket.write_q;
                socket.write_q = .{};

                while (queue.pop()) |c| {
                    try c.perform(socket, self);
                }
            }
        }
    }
}
