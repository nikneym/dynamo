const std = @import("std");
const os = std.os;
const Socket = @import("socket.zig");
const Loop = @import("backends/epoll.zig");
const Completion = @import("completion.zig");

pub fn ReadFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        loop: *Loop,
        completion: *Completion,
        socket: *Socket,
        slice: []u8,
        result: anyerror!usize,
    ) void;
}

pub fn ConnectFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        loop: *Loop,
        completion: *Completion,
        socket: *Socket,
        result: anyerror!void,
    ) void;
}

pub fn WriteFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        loop: *Loop,
        completion: *Completion,
        socket: *Socket,
        bytes: []const u8,
        result: anyerror!usize,
    ) void;
}

pub fn WritevFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        socket: *Socket,
        vectors: []const os.iovec_const,
    ) void;
}

pub fn AcceptFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        loop: *Loop,
        completion: *Completion,
        socket: *Socket,
        result: anyerror!*Socket,
    ) void;
}
