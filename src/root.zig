//! By convention, root.zig is the root source file when making a library.
const std = @import("std");

const DequeItem = struct {
    value: *Work,
    prev: std.atomic.Value(?*DequeItem),
    next: std.atomic.Value(?*DequeItem),
};

const LocalLinkedQueue = struct {
    head: std.atomic.Value(?*DequeItem),
    tail: std.atomic.Value(?*DequeItem),
    pool: std.heap.MemoryPool(DequeItem),

    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{
            .head = .init(null),
            .tail = .init(null),
            .pool = try .initPreHeat(allocator, 72),
        };
    }

    pub fn deinit(self: *@This()) void {
        self.head.store(null, .monotonic);
        self.tail.store(null, .monotonic);
        self.pool.deinit();
    }

    /// Enqueue at the tail (lock-free, single producer)
    pub fn enqueue(self: *@This(), work: *Work) !*DequeItem {
        var item = try self.pool.create();
        item.* = .{
            .value = work,
            .prev = .init(null),
            .next = .init(null),
        };

        while (true) {
            const tail = self.tail.load(.acquire);
            item.prev.store(tail, .relaxed);
            item.next.store(null, .relaxed);

            if (tail) |t| {
                // Try to link the new item after the current tail
                if (t.next.cmpxchgStrong(null, item, .acquire, .relaxed)) |old| {
                    // cmpxchgStrong failed, retry
                    continue;
                } else {
                    // cmpxchgStrong succeeded, now update tail
                    self.tail.store(item, .release);
                    break;
                }
            } else {
                // Queue is empty, try to set head and tail
                if (self.head.cmpxchgStrong(null, item, .acquire, .relaxed)) |old| {
                    // cmpxchgStrong failed, retry
                    continue;
                } else {
                    self.tail.store(item, .release);
                    break;
                }
            }
        }
        return item;
    }

    /// Dequeue from the head (lock-free, single consumer)
    pub fn dequeue(self: *@This()) ?*Work {
        while (true) {
            const head = self.head.load(.acquire);
            if (head == null) return null;

            const next = head.?.next.load(.acquire);
            if (self.head.cmpxchgStrong(head, next, .acquire, .relaxed)) |old| {
                // cmpxchgStrong failed, retry
                continue;
            } else {
                if (next == null) {
                    // Queue is now empty, update tail
                    self.tail.store(null, .release);
                } else {
                    next.?.prev.store(null, .release);
                }
                const work = head.?.value;
                self.pool.destroy(head.?);
                return work;
            }
        }
    }
};

pub const WorkQueue = struct {
    arena: std.ArrayList(Work),
    working: LocalLinkedQueue,
    
}

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
