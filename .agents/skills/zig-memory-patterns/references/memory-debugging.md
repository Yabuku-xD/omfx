# Memory Debugging in Zig

Guide to debugging memory issues, detecting leaks, and avoiding common pitfalls in Zig 0.15.2.

## GeneralPurposeAllocator Leak Detection

### Basic Leak Detection

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("MEMORY LEAK DETECTED", .{});
        }
    }

    const allocator = gpa.allocator();

    // This will leak:
    const data = try allocator.alloc(u8, 100);
    _ = data;
    // Forgot to call allocator.free(data)
}
```

Running this program prints leak information in debug builds.

### Verbose Leak Tracking

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{
    .stack_trace_frames = 10,  // Capture stack traces
    .verbose_log = true,        // Print detailed logs
}){};
defer {
    const leaked = gpa.deinit();
    if (leaked == .leak) {
        std.log.err("Leaks detected with stack traces above", .{});
    }
}
```

This captures stack traces showing where allocations occurred, helping identify leak sources.

### Safe vs Unsafe Modes

```zig
// Debug/ReleaseSafe: Leak detection enabled
var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = true,  // Enable safety checks
}){};

// ReleaseFast/ReleaseSmall: Leak detection disabled for performance
var gpa = std.heap.GeneralPurposeAllocator(.{
    .safety = false,  // Disable for production
}){};
```

## Common Memory Errors

### Double Free

```zig
test "double free detection" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const data = try allocator.alloc(u8, 100);

    allocator.free(data);
    allocator.free(data);  // ERROR: Double free detected in debug builds
}
```

Debug builds panic on double-free with message showing location.

### Use After Free

```zig
test "use after free" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    const data = try allocator.alloc(u8, 100);

    allocator.free(data);
    data[0] = 42;  // ERROR: Use after free (may crash or corrupt)
}
```

Not always caught by GPA, but tools like Valgrind/AddressSanitizer detect this.

### Memory Leak

```zig
fn leakyFunction(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    // Forgot to free!

    if (some_condition) {
        return;  // Leak
    }

    allocator.free(data);  // Only freed on one path
}

// Fix: Use defer
fn fixedFunction(allocator: std.mem.Allocator) !void {
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);  // Always freed

    if (some_condition) {
        return;  // No leak
    }
}
```

### Forgetting errdefer

```zig
fn partialInitialization(allocator: std.mem.Allocator) !*Resource {
    const resource = try allocator.create(Resource);
    // Missing: errdefer allocator.destroy(resource);

    const buffer = try allocator.alloc(u8, 1024);
    // If this allocation fails, resource leaks!

    resource.* = Resource{ .buffer = buffer };
    return resource;
}

// Fix:
fn fixedInitialization(allocator: std.mem.Allocator) !*Resource {
    const resource = try allocator.create(Resource);
    errdefer allocator.destroy(resource);  // Cleanup on error

    const buffer = try allocator.alloc(u8, 1024);
    errdefer allocator.free(buffer);

    resource.* = Resource{ .buffer = buffer };
    return resource;
}
```

## Testing for Memory Issues

### Using std.testing.allocator

```zig
test "no memory leaks" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(u8, 100);
    defer allocator.free(data);

    // Test will automatically fail if memory leaked
}

test "forgot to free" {
    const allocator = std.testing.allocator;

    const data = try allocator.alloc(u8, 100);
    _ = data;
    // TEST FAILS: Memory leak detected
}
```

`std.testing.allocator` is a GeneralPurposeAllocator configured to fail tests on leaks.

### Testing Cleanup on Error

```zig
test "cleanup on error" {
    const allocator = std.testing.allocator;

    const result = initializeResource(allocator);

    // Even if this errors, no leaks should occur
    try std.testing.expectError(error.InitFailed, result);
}
```

### Simulating Allocation Failures

```zig
test "handle allocation failure gracefully" {
    var failing_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 2 },  // Fail 3rd allocation
    );

    const allocator = failing_allocator.allocator();

    const result = processData(allocator);
    try std.testing.expectError(error.OutOfMemory, result);

    // Ensure no leaks even when allocation fails
}
```

## External Tools

### Valgrind (Linux)

```bash
# Build with debug symbols
zig build-exe main.zig

# Run with Valgrind
valgrind --leak-check=full --show-leak-kinds=all ./main

# Output shows:
# - Memory leaks with allocation sites
# - Invalid reads/writes
# - Use after free
```

Example Valgrind output:
```
==12345== HEAP SUMMARY:
==12345==     in use at exit: 1,024 bytes in 1 blocks
==12345==   total heap usage: 10 allocs, 9 frees, 10,240 bytes allocated
==12345==
==12345== 1,024 bytes in 1 blocks are definitely lost
==12345==    at 0x4C2BBAF: malloc (vg_replace_malloc.c:299)
==12345==    by 0x10918E: main.main (main.zig:15)
```

### AddressSanitizer (ASan)

```bash
# Build with AddressSanitizer
zig build-exe main.zig -fsanitize=address

# Run program
./main

# ASan detects:
# - Heap buffer overflows
# - Stack buffer overflows
# - Use after free
# - Double free
```

### MemorySanitizer (MSan)

```bash
# Build with MemorySanitizer (detects uninitialized memory)
zig build-exe main.zig -fsanitize=memory

./main
```

### UndefinedBehaviorSanitizer (UBSan)

```bash
# Detect undefined behavior
zig build-exe main.zig -fsanitize=undefined

./main
```

## Debugging Patterns

### Logging Allocations

```zig
const LoggingAllocator = struct {
    parent: std.mem.Allocator,

    fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        const self: *LoggingAllocator = @ptrCast(@alignCast(ctx));

        std.debug.print("ALLOC: {} bytes (align {})\n", .{ len, ptr_align });
        const result = self.parent.rawAlloc(len, ptr_align, ret_addr);

        if (result) |ptr| {
            std.debug.print("  -> {*}\n", .{ptr});
        } else {
            std.debug.print("  -> FAILED\n", .{});
        }

        return result;
    }

    fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        const self: *LoggingAllocator = @ptrCast(@alignCast(ctx));

        std.debug.print("FREE: {} bytes at {*}\n", .{ buf.len, buf.ptr });
        self.parent.rawFree(buf, buf_align, ret_addr);
    }

    // ... other methods
};
```

### Tracking Allocation Sizes

```zig
const AllocationTracker = struct {
    allocations: std.AutoHashMap(usize, usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !AllocationTracker {
        return .{
            .allocations = std.AutoHashMap(usize, usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AllocationTracker) void {
        if (self.allocations.count() > 0) {
            std.debug.print("LEAKS DETECTED:\n", .{});
            var iter = self.allocations.iterator();
            while (iter.next()) |entry| {
                std.debug.print("  {*}: {} bytes\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }
        self.allocations.deinit();
    }

    pub fn track(self: *AllocationTracker, ptr: usize, size: usize) !void {
        try self.allocations.put(ptr, size);
    }

    pub fn untrack(self: *AllocationTracker, ptr: usize) void {
        _ = self.allocations.remove(ptr);
    }
};
```

### Debug-Only Assertions

```zig
fn processData(allocator: std.mem.Allocator, data: []u8) void {
    std.debug.assert(data.len > 0);  // Only in debug builds

    // Process data...

    if (std.debug.runtime_safety) {
        // Extra checks only in debug/safe modes
        validateInvariants(data);
    }
}
```

## Common Pitfalls

### Pitfall 1: Returning Stack Memory

```zig
// BAD: Returning pointer to stack
fn getBadBuffer() []u8 {
    var buffer: [100]u8 = undefined;
    return &buffer;  // ERROR: Returns stack memory
}

// GOOD: Allocate on heap
fn getGoodBuffer(allocator: std.mem.Allocator) ![]u8 {
    return try allocator.alloc(u8, 100);
}

// GOOD: Use caller-provided buffer
fn fillBuffer(buffer: []u8) void {
    // Fill buffer owned by caller
}
```

### Pitfall 2: Slice Invalidation

```zig
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();

const slice = list.items;  // Get slice

try list.append(42);  // May reallocate!

// slice might now be invalid if list reallocated
```

**Fix**: Get slice after all modifications:
```zig
try list.append(42);
const slice = list.items;  // Safe
```

### Pitfall 3: Unclear Ownership

```zig
// BAD: Unclear who frees
fn processData(data: []u8) void {
    // Should I free data?
}

// GOOD: Document ownership
/// Caller owns data - function does not free
fn processData(data: []u8) void { }

/// Takes ownership of data - function frees
fn consumeData(allocator: std.mem.Allocator, data: []u8) void {
    defer allocator.free(data);
    // Process...
}
```

### Pitfall 4: Forgetting Arena Cleanup

```zig
// BAD: Arena never cleaned up
fn processRequests() !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    // Missing: defer arena.deinit();

    while (true) {
        const request = try getRequest();
        try processRequest(arena.allocator(), request);
        // Arena memory accumulates!
    }
}

// GOOD: Reset arena per request
fn processRequests() !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    while (true) {
        defer _ = arena.reset(.retain_capacity);

        const request = try getRequest();
        try processRequest(arena.allocator(), request);
    }
}
```

### Pitfall 5: Alignment Issues

```zig
// BAD: Casting without checking alignment
fn badCast(data: []u8) *u32 {
    return @ptrCast(data.ptr);  // May crash if not 4-byte aligned
}

// GOOD: Verify alignment
fn goodCast(data: []u8) ?*u32 {
    if (@intFromPtr(data.ptr) % @alignOf(u32) != 0) {
        return null;
    }
    return @ptrCast(@alignCast(data.ptr));
}

// BETTER: Use aligned allocation
const data = try allocator.alignedAlloc(u8, @alignOf(u32), size);
```

## Memory Profiling

### Counting Allocations

```zig
var allocation_count: usize = 0;
var total_bytes: usize = 0;

// Wrap allocator to count
var counting = CountingAllocator.init(base_allocator);
const allocator = counting.allocator();

// Run code...

std.debug.print("Allocations: {}\n", .{allocation_count});
std.debug.print("Total bytes: {}\n", .{total_bytes});
```

### Tracking Peak Memory

```zig
const PeakMemoryTracker = struct {
    current: usize,
    peak: usize,

    pub fn init() PeakMemoryTracker {
        return .{ .current = 0, .peak = 0 };
    }

    pub fn onAlloc(self: *PeakMemoryTracker, size: usize) void {
        self.current += size;
        if (self.current > self.peak) {
            self.peak = self.current;
        }
    }

    pub fn onFree(self: *PeakMemoryTracker, size: usize) void {
        self.current -= size;
    }

    pub fn report(self: PeakMemoryTracker) void {
        std.debug.print("Current: {} bytes\n", .{self.current});
        std.debug.print("Peak: {} bytes\n", .{self.peak});
    }
};
```

### Benchmarking Allocators

```zig
test "benchmark allocators" {
    const iterations = 1000;

    // Benchmark GPA
    {
        var timer = try std.time.Timer.start();
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            const data = try gpa.allocator().alloc(u8, 1024);
            gpa.allocator().free(data);
        }

        const elapsed = timer.read();
        std.debug.print("GPA: {} ns\n", .{elapsed});
    }

    // Benchmark Arena
    {
        var timer = try std.time.Timer.start();
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            _ = try arena.allocator().alloc(u8, 1024);
        }

        const elapsed = timer.read();
        std.debug.print("Arena: {} ns\n", .{elapsed});
    }
}
```

## Best Practices

1. **Always use defer for cleanup**: Pair allocation with defer immediately
2. **Use std.testing.allocator in tests**: Automatic leak detection
3. **Enable GPA in development**: Catches leaks and double-frees
4. **Use errdefer for partial initialization**: Cleanup on error paths
5. **Document ownership clearly**: Comment who frees memory
6. **Profile with tools**: Valgrind, ASan for production issues
7. **Test error paths**: Ensure cleanup happens on failures
8. **Avoid pointer arithmetic**: Use slices and safe abstractions
9. **Check alignment for casts**: Verify before @ptrCast
10. **Reset arenas when reusing**: Don't let memory accumulate

## Debugging Checklist

When hunting memory bugs:

- [ ] Run with GeneralPurposeAllocator in debug mode
- [ ] Check all allocation sites have corresponding frees
- [ ] Verify `defer` placement (immediately after allocation)
- [ ] Confirm `errdefer` on error paths
- [ ] Test with `std.testing.allocator`
- [ ] Run Valgrind or AddressSanitizer
- [ ] Check for slice invalidation after reallocation
- [ ] Verify alignment for pointer casts
- [ ] Look for early returns without cleanup
- [ ] Ensure arena resets in loops

## Summary

Zig provides excellent tools for memory debugging:
- **GeneralPurposeAllocator**: Built-in leak detection
- **std.testing.allocator**: Automatic test failures on leaks
- **External tools**: Valgrind, ASan for advanced detection
- **Explicit patterns**: defer, errdefer for guaranteed cleanup

Master these tools and patterns to write memory-safe Zig code that's easy to debug and maintain.
