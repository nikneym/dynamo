const std = @import("std");
const os = std.os;
const Socket = @import("socket.zig");

pub fn ReadFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        socket: *Socket,
        slice: []u8,
        length: usize,
    ) void;
}

pub fn ConnectFn(comptime T: type) type {
    return *const fn (userdata: *align(@alignOf(T)) T, socket: *Socket) void;
}

pub fn WriteFn(comptime T: type) type {
    return *const fn (
        userdata: *align(@alignOf(T)) T,
        socket: *Socket,
        bytes: []const u8,
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
        socket: *Socket,
        incoming: *Socket,
    ) void;
}
