// Taken from github.com/mitchellh/libxev.
/// MIT License
///
/// Copyright (c) 2023 Mitchell Hashimoto
///
/// Permission is hereby granted, free of charge, to any person obtaining a copy
/// of this software and associated documentation files (the "Software"), to deal
/// in the Software without restriction, including without limitation the rights
/// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
/// copies of the Software, and to permit persons to whom the Software is
/// furnished to do so, subject to the following conditions:
///
/// The above copyright notice and this permission notice shall be included in all
/// copies or substantial portions of the Software.
///
/// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
/// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
/// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
/// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
/// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
/// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
/// SOFTWARE.
const std = @import("std");

/// An intrusive queue implementation. The type T must have a field
/// "next" of type `?*T`.
///
/// For those unaware, an intrusive variant of a data structure is one in which
/// the data type in the list has the pointer to the next element, rather
/// than a higher level "node" or "container" type. The primary benefit
/// of this (and the reason we implement this) is that it defers all memory
/// management to the caller: the data structure implementation doesn't need
/// to allocate "nodes" to contain each element. Instead, the caller provides
/// the element and how its allocated is up to them.
pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        /// Head is the front of the queue and tail is the back of the queue.
        head: ?*T = null,
        tail: ?*T = null,

        /// Enqueue a new element to the back of the queue.
        pub fn push(self: *Self, v: *T) void {
            //assert(v.next == null);

            if (self.tail) |tail| {
                // If we have elements in the queue, then we add a new tail.
                tail.next = v;
                self.tail = v;
            } else {
                // No elements in the queue we setup the initial state.
                self.head = v;
                self.tail = v;
            }
        }

        /// Dequeue the next element from the queue.
        pub fn pop(self: *Self) ?*T {
            // The next element is in "head".
            const next = self.head orelse return null;

            // If the head and tail are equal this is the last element
            // so we also set tail to null so we can now be empty.
            if (self.head == self.tail) self.tail = null;

            // Head is whatever is next (if we're the last element,
            // this will be null);
            self.head = next.next;

            // We set the "next" field to null so that this element
            // can be inserted again.
            next.next = null;
            return next;
        }

        /// Returns true if the queue is empty.
        pub fn isEmpty(self: Self) bool {
            return self.head == null;
        }
    };
}
