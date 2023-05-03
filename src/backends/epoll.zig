const std = @import("std");
const os = std.os;
const net = std.net;
const mem = std.mem;
const linux = os.linux;
const EPOLL = linux.EPOLL;
const Queue = @import("../queue.zig").Queue;
// FIXME: this is a quick workaround, do not mark these pub here
pub const Completion = @import("../completion.zig");
pub const Socket = @import("../socket.zig");

const Loop = @This();
fd: os.fd_t,
allocator: mem.Allocator,
completion_pool: CompletionPool,

const CompletionPool = std.heap.MemoryPool(Completion);

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
        //std.debug.print("{}\n", .{num_events});
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

            //std.debug.print("is readable: {}\nis writable: {}\n", .{
            //    socket.isReadable(event),
            //    socket.isWritable(event),
            //});

            if (socket.isReadable(event)) {
                // get a copy of our queue and reset the original one
                queue = socket.read_q;
                socket.read_q = .{};

                while (queue.pop()) |c| {
                    try c.perform(self.allocator, socket, self);
                }
            }

            if (socket.isWritable(event)) {
                queue = socket.write_q;
                socket.write_q = .{};

                while (queue.pop()) |c| {
                    try c.perform(self.allocator, socket, self);
                }
            }
        }
    }
}
