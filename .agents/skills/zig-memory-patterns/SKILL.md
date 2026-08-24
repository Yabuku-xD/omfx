---
name: zig-memory-patterns
description: This skill should be used when the user asks questions like "how do allocators work in Zig", "explain Zig memory management", "when to use arena allocator", "how does Zig compare to Rust ownership", "how to manage memory in Zig", or asks about memory allocation patterns for programmers coming from C, C++, Rust, or garbage-collected languages.
version: 0.1.0
---

# Zig Memory Management Patterns

## Overview

This skill explains Zig's explicit memory management approach for experienced programmers. Unlike garbage-collected languages, Zig requires manual memory management through allocators. Unlike C, allocations are tracked and explicit. Unlike Rust, there's no borrow checker—Zig trusts you to manage memory correctly.

Target Zig version: **0.15.2**

## The Allocator Interface

### What is an Allocator?

An allocator is Zig's abstraction for memory allocation. Instead of calling `malloc/free` directly, pass an `Allocator` interface that provides `.alloc()`, `.free()`, `.create()`, and `.destroy()` methods.

**Key principle**: All allocations are explicit. There's no hidden memory allocation in Zig.

### The `std.mem.Allocator` Interface

```zig
pub const Allocator = struct {
    // Allocate array of T
    pub fn alloc(self: Allocator, comptime T: type, n: usize) ![]T

    // Free memory allocated with alloc
    pub fn free(self: Allocator, memory: anytype) void

    // Allocate single item
    pub fn create(self: Allocator, comptime T: type) !*T

    // Free single item allocated with create
    pub fn destroy(self: Allocator, ptr: anytype) void

    // Reallocate (grow/shrink)
    pub fn realloc(self: Allocator, old_mem: anytype, new_n: usize) ![]T

    // ... other methods
};
```

### Basic Usage Pattern

```zig
fn processData(allocator: std.mem.Allocator) !void {
    // Allocate array of 10 integers
    const numbers = try allocator.alloc(i32, 10);
    defer allocator.free(numbers);

    // Allocate single struct
    const point = try allocator.create(Point);
    defer allocator.destroy(point);

    point.* = Point{ .x = 1.0, .y = 2.0 };

    // Use numbers and point...
}
```

**Critical pattern**: Always pair allocation with deallocation:
- `.alloc()` → `.free()`
- `.create()` → `.destroy()`
- Use `defer` immediately after allocation to guarantee cleanup

## Common Allocators

### GeneralPurposeAllocator (GPA)

**Purpose**: Main allocator for general use. Detects memory leaks and double-frees in debug builds.

```zig
const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.log.err("Memory leak detected!", .{});
        }
    }

    const allocator = gpa.allocator();

    // Use allocator throughout program
    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);

    // Process data...
}
```

**When to use**:
- Default choice for most applications
- Long-lived allocations
- Need leak detection in development
- General-purpose memory needs

**Performance**: Slower than arena allocators but safe and debuggable.

### ArenaAllocator

**Purpose**: Allocate many items, free all at once. Perfect for temporary allocations with known lifetime.

```zig
fn processRequest(base_allocator: std.mem.Allocator, request: Request) !Response {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();  // Frees ALL arena allocations at once

    const arena_allocator = arena.allocator();

    // Multiple allocations - no need to free individually
    const buffer1 = try arena_allocator.alloc(u8, 100);
    const buffer2 = try arena_allocator.alloc(u8, 200);
    const temp_data = try arena_allocator.create(TempData);

    // Process request using temporary allocations...

    // All memory freed automatically by arena.deinit()
    return response;
}
```

**When to use**:
- Request/response handling (allocate during request, free after)
- Parsing temporary data
- Many small allocations with same lifetime
- Performance-critical code (very fast allocation)

**Advantage**: No individual `.free()` calls needed—bulk deallocation.

### FixedBufferAllocator

**Purpose**: Allocate from pre-allocated buffer. No heap allocation. Fails when buffer exhausted.

```zig
fn stackOnlyOperation() !void {
    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    // Allocations come from stack buffer
    const data = try allocator.alloc(u8, 100);
    // No need to free - buffer is on stack

    // Process data...

    // Memory automatically reclaimed when function returns
}
```

**When to use**:
- Embedded systems (no heap available)
- Performance-critical paths (zero heap allocation)
- Known maximum memory needs
- Stack-only execution required

**Limitation**: Fixed size—allocation fails if buffer exhausted.

### Page Allocator

**Purpose**: Direct OS page allocation. Each allocation is page-aligned and page-sized minimum.

```zig
fn allocateLargeBuffer() ![]u8 {
    const allocator = std.heap.page_allocator;

    // Allocates at least one page (typically 4KB)
    const buffer = try allocator.alloc(u8, 8192);
    defer allocator.free(buffer);

    return buffer;
}
```

**When to use**:
- Large allocations (megabytes+)
- Need page alignment
- Working with OS memory APIs
- Memory mapping

**Avoid for**: Small allocations (wastes memory due to page granularity).

## Memory Ownership Patterns

### Ownership Rules

Zig has no borrow checker. Memory ownership is **convention-based**:

1. **Caller owns**: Function receives pointer, doesn't free it
2. **Callee owns**: Function allocates and returns, caller must free
3. **Transfer ownership**: Function takes ownership, frees when done

**Document ownership in function comments or names.**

### Pattern 1: Caller Owns (Borrow)

```zig
// Caller owns data - function borrows
fn processBuffer(data: []u8) void {
    // Read/write data
    // Don't free - caller owns it
}

// Usage:
const data = try allocator.alloc(u8, 100);
defer allocator.free(data);  // Caller responsible for freeing

processBuffer(data);
```

### Pattern 2: Callee Allocates (Transfer to Caller)

```zig
// Function allocates, caller must free
fn allocateBuffer(allocator: std.mem.Allocator, size: usize) ![]u8 {
    return try allocator.alloc(u8, size);
}

// Usage:
const buffer = try allocateBuffer(allocator, 1024);
defer allocator.free(buffer);  // Caller MUST free
```

**Convention**: Function name often indicates allocation (e.g., `alloc`, `create`, `dupe`, `init`).

### Pattern 3: Callee Owns (Take Ownership)

```zig
// Function takes ownership and frees
fn consumeData(allocator: std.mem.Allocator, data: []u8) void {
    // Use data...
    allocator.free(data);  // Function frees
}

// Usage:
const data = try allocator.alloc(u8, 100);
// Don't defer free - consumeData owns it
consumeData(allocator, data);
```

### Pattern 4: Struct Ownership

```zig
const DataProcessor = struct {
    allocator: std.mem.Allocator,
    buffer: []u8,

    pub fn init(allocator: std.mem.Allocator, size: usize) !DataProcessor {
        const buffer = try allocator.alloc(u8, size);
        return DataProcessor{
            .allocator = allocator,
            .buffer = buffer,
        };
    }

    pub fn deinit(self: *DataProcessor) void {
        self.allocator.free(self.buffer);
    }
};

// Usage:
var processor = try DataProcessor.init(allocator, 1024);
defer processor.deinit();  // RAII-style cleanup
```

**Convention**: Structs with allocated resources have `init()`/`deinit()` pairs.

## RAII-Style Patterns with Defer

### Automatic Cleanup

```zig
fn withFile(path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();  // RAII: guaranteed cleanup

    const data = try allocator.alloc(u8, 1024);
    defer allocator.free(data);  // Paired with allocation

    // Even if error occurs, file closes and data freed
    try file.read(data);
}
```

### Error-Specific Cleanup with `errdefer`

```zig
fn createResource(allocator: std.mem.Allocator) !*Resource {
    const resource = try allocator.create(Resource);
    errdefer allocator.destroy(resource);  // Only on error

    const buffer = try allocator.alloc(u8, 1024);
    errdefer allocator.free(buffer);

    resource.* = Resource{ .buffer = buffer };

    try resource.initialize();  // If fails, cleanup happens
    return resource;
}
```

**Key difference from RAII**:
- C++: RAII uses destructors (automatic)
- Zig: RAII uses `defer` (explicit but guaranteed)

## Comparisons to Other Languages

### vs C (malloc/free)

**C**:
```c
void* data = malloc(1024);
// Use data...
free(data);  // Easy to forget or double-free
```

**Zig**:
```zig
const data = try allocator.alloc(u8, 1024);
defer allocator.free(data);  // Paired with allocation, guaranteed
```

**Advantages over C**:
- Allocator interface allows different allocation strategies
- `defer` guarantees cleanup (no missed frees)
- Debug builds detect leaks and double-frees
- Errors for allocation failures (`!` return type)

### vs Garbage Collected Languages (Go, Java, Python)

**GC Language**:
```go
data := make([]byte, 1024)
// Use data...
// GC automatically frees (eventually)
```

**Zig**:
```zig
const data = try allocator.alloc(u8, 1024);
defer allocator.free(data);  // Explicit, immediate
```

**Key differences**:
- **Zig**: Explicit allocation/deallocation, deterministic
- **GC**: Hidden allocation, non-deterministic collection
- **Zig**: No GC pauses, predictable performance
- **GC**: Easier to write, harder to optimize

**When to use Zig over GC**: Real-time systems, performance-critical code, resource-constrained environments.

### vs Rust (Ownership & Borrowing)

**Rust**:
```rust
fn process_data(data: Vec<u8>) {
    // Compiler enforces ownership and borrowing
    // Automatically dropped at end of scope
}
```

**Zig**:
```zig
fn processData(allocator: std.mem.Allocator, data: []u8) void {
    defer allocator.free(data);  // Manual but explicit
    // No borrow checker - you ensure correctness
}
```

**Key differences**:
- **Rust**: Borrow checker enforces safety at compile time
- **Zig**: Manual management with explicit allocator
- **Rust**: Safe by default, harder to write
- **Zig**: Trusts programmer, easier to write, easier to make mistakes

**Zig philosophy**: Give programmers control, make allocation explicit, trust correctness.

## Common Patterns

### Arena for Temporary Work

```zig
fn processMany(base_allocator: std.mem.Allocator, items: []Item) !void {
    for (items) |item| {
        var arena = std.heap.ArenaAllocator.init(base_allocator);
        defer arena.deinit();

        // Process item with temporary allocations
        try processOne(arena.allocator(), item);
        // All temporary memory freed
    }
}
```

### Allocator Composition

```zig
fn performanceTest(base_allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(base_allocator);
    defer arena.deinit();

    var buffer: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);

    // Use stack buffer first, fall back to arena
    const data = fba.allocator().alloc(u8, 100) catch
        try arena.allocator().alloc(u8, 100);

    // Process data...
    // Arena cleanup handles fallback, FBA is stack-based
}
```

### Growing Buffers

```zig
fn buildDynamicArray(allocator: std.mem.Allocator) ![]u8 {
    var buffer = try allocator.alloc(u8, 10);
    var len: usize = 0;

    // Need more space?
    if (len >= buffer.len) {
        buffer = try allocator.realloc(buffer, buffer.len * 2);
    }

    return buffer;
}

// Better: use ArrayList
fn buildWithArrayList(allocator: std.mem.Allocator) ![]u8 {
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    try list.appendSlice("data");
    return try list.toOwnedSlice();  // Transfer ownership to caller
}
```

## Best Practices

1. **Pass allocators explicitly**: Functions that allocate take `allocator` parameter
2. **Use `defer` immediately**: Pair allocation with `defer free`
3. **Prefer arena for temporary data**: Fast and bulk deallocation
4. **Document ownership**: Make clear who frees memory
5. **Use GPA for development**: Detects leaks and errors
6. **FixedBuffer for stack-only**: Avoid heap in performance paths
7. **Test with leak detection**: Run with GPA in tests

## Memory Safety Tips

**Always pair operations**:
- `alloc` ↔ `free`
- `create` ↔ `destroy`
- `init` ↔ `deinit`
- `acquire` ↔ `release`

**Use `defer` for guaranteed cleanup**:
```zig
const data = try allocator.alloc(u8, 100);
defer allocator.free(data);  // ALWAYS, right after allocation
```

**Test with debug builds**:
- Debug mode has runtime safety checks
- GPA detects leaks and double-frees
- Use `std.testing.allocator` in tests (leak-detecting allocator)

## Additional Resources

### Reference Files

For detailed patterns and advanced techniques:
- **`references/allocator-patterns.md`** - Advanced allocator usage, custom allocators, performance optimization
- **`references/memory-debugging.md`** - Debugging leaks, tools, common pitfalls

### Official Documentation

- [Zig Memory Management](https://ziglang.org/documentation/0.15.2/#Memory)
- [Standard Library Allocators](https://ziglang.org/documentation/0.15.2/std/#std.heap)

## Quick Reference

| Allocator | Use Case | Speed | Safety |
|-----------|----------|-------|--------|
| GeneralPurposeAllocator | Default, general use | Medium | High (leak detection) |
| ArenaAllocator | Temporary data, bulk free | Fast | Medium |
| FixedBufferAllocator | Stack-only, no heap | Fastest | Low (fixed size) |
| page_allocator | Large allocations | Slow | Low (no leak detection) |

| Pattern | Ownership | Cleanup |
|---------|-----------|---------|
| Borrow | Caller owns | Caller frees |
| Allocate & Return | Caller owns | Caller frees |
| Take Ownership | Callee owns | Callee frees |
| Struct with init/deinit | Struct owns | Call deinit |

## Summary

Zig memory management is:
- **Explicit**: All allocations visible, allocator passed as parameter
- **Flexible**: Different allocators for different use cases
- **Deterministic**: No GC pauses, predictable performance
- **Safe with discipline**: `defer` ensures cleanup, debug builds detect errors

Master allocators and ownership patterns to write efficient, leak-free Zig code.
