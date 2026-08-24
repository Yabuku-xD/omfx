# Advanced Allocator Patterns in Zig

Comprehensive guide to advanced memory allocation patterns, custom allocators, and performance optimization in Zig 0.15.2.

## Custom Allocators

### Creating a Custom Allocator

```zig
const std = @import("std");

const CountingAllocator = struct {
    parent_allocator: std.mem.Allocator,
    allocations: usize,
    deallocations: usize,
    bytes_allocated: usize,

    pub fn init(parent: std.mem.Allocator) CountingAllocator {
        return .{
            .parent_allocator = parent,
            .allocations = 0,
            .deallocations = 0,
            .bytes_allocated = 0,
        };
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));

        const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |ptr| {
            self.allocations += 1;
            self.bytes_allocated += len;
            return ptr;
        }
        return null;
    }

    fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent_allocator.rawResize(buf, buf_align, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.deallocations += 1;
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }

    pub fn report(self: CountingAllocator) void {
        std.debug.print("Allocations: {}\n", .{self.allocations});
        std.debug.print("Deallocations: {}\n", .{self.deallocations});
        std.debug.print("Bytes allocated: {}\n", .{self.bytes_allocated});
        std.debug.print("Potential leaks: {}\n", .{self.allocations - self.deallocations});
    }
};

// Usage:
var counting = CountingAllocator.init(std.heap.page_allocator);
const allocator = counting.allocator();

const data = try allocator.alloc(u8, 1024);
defer allocator.free(data);

counting.report();
```

### Logging Allocator

```zig
const LoggingAllocator = struct {
    parent_allocator: std.mem.Allocator,
    log_file: std.fs.File,

    pub fn init(parent: std.mem.Allocator, log_file: std.fs.File) LoggingAllocator {
        return .{
            .parent_allocator = parent,
            .log_file = log_file,
        };
    }

    pub fn allocator(self: *LoggingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *LoggingAllocator = @ptrCast(@alignCast(ctx));

        const result = self.parent_allocator.rawAlloc(len, ptr_align, ret_addr);
        if (result) |ptr| {
            self.log_file.writer().print("ALLOC: {} bytes at {*}\n", .{ len, ptr }) catch {};
            return ptr;
        }
        self.log_file.writer().print("ALLOC FAILED: {} bytes\n", .{len}) catch {};
        return null;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *LoggingAllocator = @ptrCast(@alignCast(ctx));
        self.log_file.writer().print("FREE: {} bytes at {*}\n", .{ buf.len, buf.ptr }) catch {};
        self.parent_allocator.rawFree(buf, buf_align, ret_addr);
    }

    // ... resize implementation
};
```

## Advanced Arena Patterns

### Nested Arenas

```zig
fn processWithNestedArenas(base_allocator: std.mem.Allocator) !void {
    var outer_arena = std.heap.ArenaAllocator.init(base_allocator);
    defer outer_arena.deinit();

    const outer_data = try outer_arena.allocator().alloc(u8, 1000);

    // Inner arena for temporary work
    var inner_arena = std.heap.ArenaAllocator.init(outer_arena.allocator());
    defer inner_arena.deinit();

    const temp_data = try inner_arena.allocator().alloc(u8, 500);
    // Use temp_data...
    // Inner arena freed first, then outer arena
}
```

### Arena with Manual Reset

```zig
fn processStream(base_allocator: std.mem.Allocator, stream: Stream) !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    while (try stream.next()) |item| {
        defer _ = arena.reset(.retain_capacity);  // Reset after each item

        // Allocate temporary data for item processing
        const temp = try arena.allocator().alloc(u8, item.size);
        try processItem(item, temp);
        // Memory reused for next iteration
    }
}
```

### Arena-Based Object Pool

```zig
const ObjectPool = struct {
    arena: std.heap.ArenaAllocator,
    objects: std.ArrayList(*Object),

    pub fn init(base_allocator: std.mem.Allocator) ObjectPool {
        return .{
            .arena = std.heap.ArenaAllocator.init(base_allocator),
            .objects = std.ArrayList(*Object).init(base_allocator),
        };
    }

    pub fn deinit(self: *ObjectPool) void {
        self.objects.deinit();
        self.arena.deinit();
    }

    pub fn acquire(self: *ObjectPool) !*Object {
        if (self.objects.popOrNull()) |obj| {
            return obj;
        }

        // Allocate new object from arena
        const obj = try self.arena.allocator().create(Object);
        return obj;
    }

    pub fn release(self: *ObjectPool, obj: *Object) !void {
        obj.reset();
        try self.objects.append(obj);
    }

    pub fn reset(self: *ObjectPool) void {
        self.objects.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
    }
};
```

## Memory Pooling

### Simple Memory Pool

```zig
fn MemoryPool(comptime T: type, comptime pool_size: usize) type {
    return struct {
        pool: [pool_size]T,
        free_list: std.ArrayList(usize),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            return Self{
                .pool = undefined,
                .free_list = try std.ArrayList(usize).initCapacity(allocator, pool_size),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.free_list.deinit();
        }

        pub fn acquire(self: *Self) ?*T {
            if (self.free_list.popOrNull()) |index| {
                return &self.pool[index];
            }
            return null;
        }

        pub fn release(self: *Self, item: *T) !void {
            const index = (@intFromPtr(item) - @intFromPtr(&self.pool[0])) / @sizeOf(T);
            try self.free_list.append(index);
        }
    };
}

// Usage:
var pool = try MemoryPool(MyStruct, 100).init(allocator);
defer pool.deinit();

const obj = pool.acquire() orelse return error.PoolExhausted;
defer pool.release(obj) catch {};

obj.* = MyStruct{ .field = 42 };
```

### Slab Allocator

```zig
const SlabAllocator = struct {
    const Slab = struct {
        data: []u8,
        used: usize,
    };

    slabs: std.ArrayList(Slab),
    slab_size: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, slab_size: usize) SlabAllocator {
        return .{
            .slabs = std.ArrayList(Slab).init(allocator),
            .slab_size = slab_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SlabAllocator) void {
        for (self.slabs.items) |slab| {
            self.allocator.free(slab.data);
        }
        self.slabs.deinit();
    }

    pub fn alloc(self: *SlabAllocator, size: usize) ![]u8 {
        if (size > self.slab_size) {
            return error.AllocationTooLarge;
        }

        // Try to allocate from existing slab
        if (self.slabs.items.len > 0) {
            const slab = &self.slabs.items[self.slabs.items.len - 1];
            if (slab.used + size <= slab.data.len) {
                const start = slab.used;
                slab.used += size;
                return slab.data[start..][0..size];
            }
        }

        // Allocate new slab
        const slab_data = try self.allocator.alloc(u8, self.slab_size);
        try self.slabs.append(.{ .data = slab_data, .used = size });
        return slab_data[0..size];
    }
};
```

## Stack-Based Patterns

### Stack Fallback Allocator

```zig
const StackFallbackAllocator = struct {
    buffer: []u8,
    used: usize,
    fallback: std.mem.Allocator,

    pub fn init(buffer: []u8, fallback: std.mem.Allocator) StackFallbackAllocator {
        return .{
            .buffer = buffer,
            .used = 0,
            .fallback = fallback,
        };
    }

    pub fn allocator(self: *StackFallbackAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *StackFallbackAllocator = @ptrCast(@alignCast(ctx));

        // Try stack allocation
        const aligned_used = std.mem.alignForward(usize, self.used, ptr_align);
        if (aligned_used + len <= self.buffer.len) {
            const result = self.buffer[aligned_used..][0..len];
            self.used = aligned_used + len;
            return result.ptr;
        }

        // Fall back to heap
        return self.fallback.rawAlloc(len, ptr_align, ret_addr);
    }

    // ... resize and free implementations
};

// Usage:
var stack_buffer: [4096]u8 = undefined;
var fallback = StackFallbackAllocator.init(&stack_buffer, std.heap.page_allocator);
const allocator = fallback.allocator();

// Small allocations use stack, large ones use heap
const small = try allocator.alloc(u8, 100);  // From stack
const large = try allocator.alloc(u8, 10000);  // From heap
```

## Performance Optimization

### Allocation Batching

```zig
fn batchAllocate(allocator: std.mem.Allocator, count: usize) ![][]u8 {
    // Better: Single large allocation
    const total_size = count * 1024;
    const buffer = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buffer);

    const result = try allocator.alloc([]u8, count);
    for (result, 0..) |*slice, i| {
        slice.* = buffer[i * 1024..][0..1024];
    }

    return result;
}

// vs: Many small allocations (slower)
fn individualAllocate(allocator: std.mem.Allocator, count: usize) ![][]u8 {
    const result = try allocator.alloc([]u8, count);
    for (result) |*slice| {
        slice.* = try allocator.alloc(u8, 1024);
    }
    return result;
}
```

### Reusing Allocations

```zig
const Buffer = struct {
    data: []u8,
    len: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Buffer {
        return Buffer{
            .data = try allocator.alloc(u8, capacity),
            .len = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
    }

    pub fn reset(self: *Buffer) void {
        self.len = 0;  // Reuse buffer without reallocating
    }

    pub fn ensureCapacity(self: *Buffer, new_capacity: usize) !void {
        if (new_capacity <= self.data.len) return;

        const new_data = try self.allocator.realloc(self.data, new_capacity);
        self.data = new_data;
    }
};
```

### Alignment Optimization

```zig
// Properly aligned allocation for SIMD
fn allocateAligned(allocator: std.mem.Allocator, size: usize, alignment: usize) ![]align(alignment) u8 {
    const ptr = try allocator.alignedAlloc(u8, alignment, size);
    return @as([]align(alignment) u8, @alignCast(ptr));
}

// Usage for SIMD operations
const simd_buffer = try allocateAligned(allocator, 1024, 32);  // 32-byte aligned
defer allocator.free(simd_buffer);
```

## Testing Allocators

### Test Allocator

```zig
test "memory operations" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);

    // Test will fail if memory leaked
    try std.testing.expect(data.len == 100);
}
```

### Failing Allocator for Testing

```zig
const FailingAllocator = struct {
    parent: std.mem.Allocator,
    fail_after: usize,
    allocations: usize,

    pub fn init(parent: std.mem.Allocator, fail_after: usize) FailingAllocator {
        return .{
            .parent = parent,
            .fail_after = fail_after,
            .allocations = 0,
        };
    }

    pub fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));

        if (self.allocations >= self.fail_after) {
            return null;  // Simulate allocation failure
        }

        self.allocations += 1;
        return self.parent.rawAlloc(len, ptr_align, ret_addr);
    }

    // ... other methods
};

// Test error handling
test "handle allocation failure" {
    var failing = FailingAllocator.init(std.testing.allocator, 2);
    const allocator = failing.allocator();

    _ = try allocator.alloc(u8, 100);  // Success
    _ = try allocator.alloc(u8, 100);  // Success

    const result = allocator.alloc(u8, 100);  // Should fail
    try std.testing.expectError(error.OutOfMemory, result);
}
```

## Allocator Selection Guide

### Decision Tree

```
Need deterministic memory?
├─ Yes → Use FixedBufferAllocator (stack-based)
└─ No
   ├─ Many short-lived allocations?
   │  └─ Yes → Use ArenaAllocator
   └─ No
      ├─ Need leak detection?
      │  └─ Yes → Use GeneralPurposeAllocator
      └─ No
         ├─ Very large allocations?
         │  └─ Yes → Use page_allocator
         └─ Default → GeneralPurposeAllocator
```

### Performance Characteristics

| Allocator | Alloc Speed | Free Speed | Memory Overhead | Use Case |
|-----------|-------------|------------|-----------------|----------|
| FixedBufferAllocator | Fastest | N/A | None | Stack-only |
| ArenaAllocator | Fast | Instant (bulk) | Low | Request scope |
| GeneralPurposeAllocator | Medium | Medium | Medium | General use |
| page_allocator | Slow | Slow | High | Large blocks |

## Common Patterns Summary

### Temporary Allocations

```zig
var arena = std.heap.ArenaAllocator.init(base_allocator);
defer arena.deinit();
// Use arena.allocator() for temporary work
```

### Long-Lived Allocations

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();
// Use for program lifetime
```

### Stack-First, Heap Fallback

```zig
var buffer: [4096]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buffer);
const data = fba.allocator().alloc(u8, 100) catch
    try heap_allocator.alloc(u8, 100);
```

### Struct with Owned Memory

```zig
const MyStruct = struct {
    allocator: std.mem.Allocator,
    data: []u8,

    pub fn init(allocator: std.mem.Allocator) !MyStruct {
        return .{
            .allocator = allocator,
            .data = try allocator.alloc(u8, 1024),
        };
    }

    pub fn deinit(self: *MyStruct) void {
        self.allocator.free(self.data);
    }
};
```

## Best Practices

1. **Profile before optimizing**: Measure allocation patterns
2. **Use arenas for request handling**: Fast bulk deallocation
3. **Prefer stack for small buffers**: FixedBufferAllocator when possible
4. **Test with FailingAllocator**: Verify error handling
5. **Batch allocations**: Single large allocation vs many small
6. **Align for SIMD**: Use alignedAlloc for vectorized code
7. **Reset arenas when reusing**: `arena.reset(.retain_capacity)`
8. **Document ownership**: Clear who frees memory

Memory management in Zig is powerful and flexible. Choose the right allocator for your use case, and leverage patterns like arenas and pools for optimal performance.
