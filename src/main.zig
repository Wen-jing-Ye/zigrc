const std = @import("std");
const builtin = @import("builtin");

/// A single threaded, strong reference to a reference-counted value.
pub fn Rc(comptime T: type) type {
    return struct {
        value: *T,
        alloc: std.mem.Allocator,

        const Self = @This();
        const Inner = RcInner(T);

        /// Creates a new reference-counted value.
        pub fn init(alloc: std.mem.Allocator, t: T) !Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 1, .weak = 1, .value = t };
            return Self{ .value = &inner.value, .alloc = alloc };
        }

        /// Converts an `Rc` into an `Arc`.
        pub fn intoAtomic(self: Self) Arc(T) {
            if (builtin.single_thread) {
                return self;
            } else {
                return Arc(T){ .value = self.value, .alloc = self.alloc };
            }
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: *const Self) usize {
            return self.innerPtr().strong;
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: *const Self) usize {
            return self.innerPtr().weak - 1;
        }

        /// Increments the strong count
        pub fn retain(self: *const Self) Self {
            self.innerPtr().strong += 1;
            return self.*;
        }

        /// Creates a new weak reference to the pointed value
        pub fn downgrade(self: *const Self) Weak(T) {
            return Weak(T).init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        pub fn release(self: *const Self) void {
            const ptr = self.innerPtr();

            ptr.strong -= 1;
            if (ptr.strong == 0) {
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    self.alloc.destroy(ptr);
                }
            }
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero
        pub fn deinitWithFn(self: *const Self, f: fn (T) void) void {
            const ptr = self.innerPtr();

            ptr.strong -= 1;
            if (ptr.strong == 0) {
                f(self.value.*);

                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    self.alloc.destroy(ptr);
                }
            }
        }

        inline fn innerPtr(self: *const Self) *Inner {
            return @fieldParentPtr(Inner, "value", self.value);
        }
    };
}

/// A single threaded, weak reference to a reference-counted value.
pub fn Weak(comptime T: type) type {
    return struct {
        inner: ?*align(@alignOf(Inner)) anyopaque = null,
        alloc: std.mem.Allocator,

        const Self = @This();
        const Inner = RcInner(T);

        /// Creates a new weak reference
        pub fn init(parent: *const Rc(T)) Self {
            const ptr = parent.innerPtr();
            ptr.weak += 1;
            return Self{ .inner = ptr, .alloc = parent.alloc };
        }

        /// Converts an `Weak` into an `Aweak`.
        pub fn intoAtomic(self: Self) Aweak(T) {
            if (builtin.single_thread) {
                return self;
            } else {
                return Aweak(T){ .inner = self.inner, .alloc = self.alloc };
            }
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: *const Self) usize {
            return (self.innerPtr() orelse return 0).strong;
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: *const Self) usize {
            return (self.innerPtr() orelse return 0).weak - 1;
        }

        /// Attempts to upgrade the weak pointer to an `Rc`, delaying dropping of the inner value if successful.
        ///
        /// Returns `null` if the inner value has since been dropped.
        pub fn upgrade(self: *Self) ?Rc(T) {
            const ptr = self.innerPtr() orelse return null;

            if (ptr.strong == 0) {
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    self.alloc.destroy(*ptr);
                    ptr = null;
                }
                return null;
            }

            ptr.strong += 1;
            return Rc(T){
                .value = ptr.value,
                .alloc = self.alloc,
            };
        }

        /// Decrements the weak reference count, deallocating if it reaches zero.
        pub fn release(self: *const Self) void {
            if (self.innerPtr()) |*ptr| {
                ptr.weak -= 1;
                if (ptr.weak == 0) {
                    self.alloc.destroy(*ptr);
                    ptr = null;
                }
            }
        }

        inline fn innerPtr(self: *const Self) ?*Inner {
            return @ptrCast(?*Inner, self.inner);
        }
    };
}

/// A multi-threaded, strong reference to a reference-counted value.
pub fn Arc(comptime T: type) type {
    if (builtin.single_thread) {
        return Rc(T);
    }

    return struct {
        value: *T,
        alloc: std.mem.Allocator,

        const Self = @This();
        const Inner = RcInner(T);

        /// Creates a new reference-counted value.
        pub fn init(alloc: std.mem.Allocator, t: T) !Self {
            const inner = try alloc.create(Inner);
            inner.* = Inner{ .strong = 1, .weak = 1, .value = t };
            return Self{ .value = &inner.value, .alloc = alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: *const Self) usize {
            return @atomicLoad(usize, &self.innerPtr().strong, .Acquire);
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: *const Self) usize {
            return @atomicLoad(usize, &self.innerPtr().weak, .Acquire) - 1;
        }

        /// Increments the strong count
        pub fn retain(self: *const Self) Self {
            _ = @atomicRmw(usize, self.innerPtr().strong, .Add, 1, .AcqRel);
            return self.*;
        }

        /// Creates a new weak reference to the pointed value
        pub fn downgrade(self: *const Self) Aweak(T) {
            return Aweak(T).init(self);
        }

        /// Decrements the reference count, deallocating if the weak count reaches zero.
        pub fn release(self: *const Self) void {
            const ptr = self.innerPtr();

            if (@atomicRmw(usize, ptr.strong, .Sub, 1, .AcqRel) == 0) {
                if (@atomicRmw(usize, ptr.weak, .Sub, 1, .AcqRel) == 0) {
                    self.alloc.destroy(ptr);
                }
            }
        }

        /// Decrements the reference count, deallocating the weak count reaches zero,
        /// and executing `f` if the strong count reaches zero
        pub fn deinitWithFn(self: *const Self, f: fn (T) void) void {
            const ptr = self.innerPtr();

            if (@atomicRmw(usize, ptr.strong, .Sub, 1, .AcqRel) == 0) {
                f(self.value.*);
                if (@atomicRmw(usize, ptr.weak, .Sub, 1, .AcqRel) == 0) {
                    self.alloc.destroy(ptr);
                }
            }
        }

        inline fn innerPtr(self: *const Self) *Inner {
            return @fieldParentPtr(Inner, "value", self.value);
        }
    };
}

/// A multi-threaded, weak reference to a reference-counted value.
pub fn Aweak(comptime T: type) type {
    if (builtin.single_thread) {
        return Weak(T);
    }

    return struct {
        inner: ?*align(@alignOf(Inner)) anyopaque = null,
        alloc: std.mem.Allocator,

        const Self = @This();
        const Inner = RcInner(T);

        /// Creates a new weak reference
        pub fn init(parent: *const Arc(T)) Self {
            const ptr = parent.innerPtr();
            _ = @atomicRmw(usize, &ptr.weak, .Add, 1, .AcqRel);
            return Self{ .inner = ptr, .alloc = parent.alloc };
        }

        /// Gets the number of strong references to this value.
        pub fn strongCount(self: *const Self) usize {
            const ptr = self.innerPtr() orelse return 0;
            return @atomicLoad(usize, &ptr.strong, .Acquire);
        }

        /// Gets the number of weak references to this value.
        pub fn weakCount(self: *const Self) usize {
            const ptr = self.innerPtr() orelse return 0;
            return @atomicLoad(usize, &ptr.weak, .Acquire) - 1;
        }

        /// Attempts to upgrade the weak pointer to an `Arc`, delaying dropping of the inner value if successful.
        ///
        /// Returns `null` if the inner value has since been dropped.
        pub fn upgrade(self: *Self) ?Arc(T) {
            const ptr = self.innerPtr() orelse return null;

            while (true) {
                const prev = @atomicLoad(usize, &ptr.strong, .Acquire);

                if (prev == 0) {
                    if (@atomicRmw(usize, &ptr.weak, .Sub, 1, .AcqRel) == 0) {
                        self.alloc.destroy(*ptr);
                        self.ptr = null;
                    }
                    return null;
                }

                if (!@cmpxchgStrong(usize, &ptr.strong, prev, prev + 1, .Acquire, .Relaxed)) {
                    return Arc(T){
                        .value = ptr.value,
                        .alloc = self.alloc,
                    };
                }

                std.atomic.spinLoopHint();
            }
        }

        /// Decrements the weak reference count, deallocating if it reaches zero.
        pub fn release(self: *const Self) void {
            if (self.innerPtr()) |*ptr| {
                if (@atomicRmw(usize, ptr.weak, .Sub, 1, .AcqRel) == 0) {
                    self.alloc.destroy(*ptr);
                    ptr = null;
                }
            }
        }

        inline fn innerPtr(self: *const Self) ?*Inner {
            return @ptrCast(?*Inner, self.inner);
        }
    };
}

fn RcInner(comptime T: type) type {
    return struct {
        strong: usize,
        weak: usize,
        value: T,
    };
}
