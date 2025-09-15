//*********************************************************
// Knödel v0.1 - tiny single file ECS.                    *
// 2025 Lorenz Mielke - https://github.com/Lommix/knoedel *
//*********************************************************

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const cprint = std.fmt.comptimePrint;

pub const MB: usize = 1024 * 1000;
pub const GB: usize = MB * 1000;

/// ECS configuration
/// CRITICAL: components are locked to 128!
/// TODO: reimplement comptime comp & res size!
pub const AppDesc = struct {
    thread_count: comptime_int = 8,
    max_frame_mem: usize = 64 * MB,
    max_components: comptime_int = 128, // TODO: reimplement, this does currently nothing
    // TODO: defines max components and resources bit sets
    // FlagType: type = u8,
};

/// The memory dictator
pub const Memtator = struct {
    const Self = @This();
    const Stats = struct {
        world_mem: usize,
        frame_percent: f32,
        frame_used_mb: usize,
    };
    // ---------------------------------------
    frame_sector: []u8, // frame arena
    world_arena: std.heap.ArenaAllocator,
    world_mutex: std.Thread.Mutex = .{},
    world_mem_size: usize = 0,
    frame_alloc: std.heap.FixedBufferAllocator,
    parent: std.mem.Allocator,

    /// requires pinned postion on memory.
    pub fn init(self: *Self, allocator: std.mem.Allocator, frame_mem: usize) !void {
        self.parent = allocator;
        self.frame_sector = try allocator.alloc(u8, frame_mem);
        self.world_arena = std.heap.ArenaAllocator.init(allocator);
        self.frame_alloc = std.heap.FixedBufferAllocator.init(self.frame_sector);
    }

    pub fn refreshVTable(self: *Self, gpa: std.mem.Allocator) void {
        self.parent = gpa;
        self.world_arena.child_allocator = gpa;
    }

    pub fn deinit(self: *Self) void {
        self.parent.free(self.frame_sector);
        self.world_arena.deinit();
        self.frame_alloc.reset();
    }

    /// general purpose world allocator. Lifetime = App
    /// # TODO: add beter mem tracing
    pub fn world(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.world_mutex.lock();
        defer self.world_mutex.unlock();

        self.world_mem_size +|= len;
        return self.world_arena.allocator().rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.world_mutex.lock();
        defer self.world_mutex.unlock();
        // self.world_mem_size += new_len - buf.len;
        return self.world_arena.allocator().rawResize(buf, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.world_mutex.lock();
        defer self.world_mutex.unlock();

        return self.world_arena.allocator().rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.world_mutex.lock();
        defer self.world_mutex.unlock();

        self.world_mem_size -|= buf.len;
        return self.world_arena.allocator().rawFree(buf, alignment, ret_addr);
    }

    /// General purpose frame allocator. Lifetime = single frame
    /// Backed by a buffer allocator. No free, resize or remap!
    pub fn frame(self: *Self) std.mem.Allocator {
        return self.frame_alloc.threadSafeAllocator();
    }

    /// reset the frame arena
    pub fn resetFrame(self: *Self) void {
        self.frame_alloc.reset();
    }

    /// # TODO: world_mem is very unpresice
    pub fn stats(self: *Self) Stats {
        return Stats{
            .world_mem = self.world_arena.queryCapacity(),
            .frame_percent = @floatCast(@as(f64, @floatFromInt(self.frame_alloc.end_index)) / @as(f64, @floatFromInt(self.frame_sector.len))),
            .frame_used_mb = @divTrunc(self.frame_alloc.end_index, MB),
        };
    }
};

// ------------------------------------------------------------------------------
/// Error Union of what can go wrong
/// # TODO: needs some cleanup and renaming
pub const EcsError = error{
    ResourceNotFound,
    SystemFailure,
    SystemConditionFailure,
    ComponentNotFound,
    EntityNotFound,
    UnknownType,
    SerializeError,
    DeserlizeError,
    EndOfStream,
    ComponentListMismatch,
    TypeIsNotInQuery,
} || std.mem.Allocator.Error || anyerror;

pub const Entity = enum(u64) {
    placeholder,
    _,

    pub inline fn id(ent: *const Entity) u32 {
        return ent.fields().idx;
    }

    pub inline fn gen(ent: *const Entity) u32 {
        return ent.fields().gen;
    }

    pub inline fn new(idx: u32) Entity {
        const f = Fields{ .idx = idx, .gen = 0 };
        return @as(*const Entity, @ptrCast(&f)).*;
    }

    pub fn incGen(ent: *Entity) void {
        var f = ent.fields();
        f.gen += 1;

        ent.* = @as(*const Entity, @ptrCast(&f)).*;
    }

    inline fn fields(ent: *const Entity) Fields {
        return @as(*const Fields, @ptrCast(ent)).*;
    }

    const Fields = packed struct {
        idx: u32,
        gen: u32,
    };
};

pub const Parent = struct {
    entity: Entity = .placeholder,
};

pub const Children = struct {
    items: std.ArrayList(Entity) = .{},

    pub fn slice(self: *const Children) []const Entity {
        return self.items.items;
    }

    pub fn deinit(self: *Children, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
    }
};

// ------------------------------------------------------------------------------

/// The core ECS struct. Owner of everything
/// Needs to have a fixed position in memory and called init on.
pub fn App(comptime desc: AppDesc) type {
    return struct {
        pub const ComponentMask = std.bit_set.IntegerBitSet(desc.max_components);
        pub const VoidComponentMask = ComponentMask.initEmpty();
        // TODO: finally finish the naming refactoring
        const World = @This();
        //-------------------------
        memtator: Memtator,
        entities: struct {
            entity_mutex: std.Thread.Mutex = .{},
            unused: std.ArrayList(Entity) = .{},
            count: u32 = 0,
        } = .{},
        // ---------------------------------------
        archtypes: ArchRegistry = .{},
        resources: ResourceRegistry = .{},
        systems: SystemRegistry = .{},
        commands: CommandRegistry = .{},
        hooks: HookRegistry(desc) = .{},
        world_tick: u32 = 0,
        // ---------------------------------------

        pub fn init(self: *World, gpa: std.mem.Allocator) EcsError!void {
            self.systems = .{};
            self.commands = .{};
            self.entities = .{};
            self.resources = .{};
            self.archtypes = .{};
            self.hooks = .{};
            self.world_tick = 0;
            try self.memtator.init(gpa, desc.max_frame_mem);
            try self.systems.init(self.memtator.world());
        }

        const EntityRegistry = struct {
            unused: std.ArrayList(Entity) = .{},
            count: u32 = 0,
        };

        ///! valid check
        pub fn isValid(self: *const World, ent: Entity) bool {
            return self.archtypes.entity_lookup.contains(ent);
        }

        /// end?
        pub fn deinit(self: *World) void {
            self.memtator.deinit();
        }

        /// modify the world and a thread safe way
        pub fn getCommands(self: *World) Commands {
            return Commands{
                .world = self,
                .reg = &self.commands,
                .frame_gpa = self.memtator.frame(),
                .world_gpa = self.memtator.world(),
            };
        }

        /// run a system schedule in lock free parallel
        pub fn runPar(self: *World, schedule: anytype, flush_commands_after: bool) void {
            self.systems.runPar(schedule, self) catch return;
            if (flush_commands_after) {
                self.flushCommands() catch |err| std.debug.print("{any}\n", .{err});
            }
        }

        /// run a system schedule in 'order' (depending on order added)
        pub fn run(self: *World, schedule: anytype, flush_commands_after: bool) void {
            self.systems.run(schedule, self) catch return;
            if (flush_commands_after) {
                self.flushCommands() catch |err| std.debug.print("{any}\n", .{err});
            }
        }

        /// insert a resource
        pub fn addResource(self: *World, res: anytype) !void {
            try self.resources.register(self.memtator.world(), res);
        }

        pub fn addOnDespawnHook(
            self: *World,
            comptime T: type,
            comptime hook_fn: *const fn (*T, Entity, *World) EcsError!void,
        ) EcsError!void {
            try self.hooks.OnDespawnComp(self.memtator.world(), T, hook_fn);
        }

        pub fn addOnAddHook(
            self: *World,
            comptime T: type,
            comptime hook_fn: *const fn (*T, Entity, *World) EcsError!void,
        ) EcsError!void {
            try self.hooks.OnAddComp(self.memtator.world(), T, hook_fn);
        }

        pub fn addOnRemoveHook(
            self: *World,
            comptime T: type,
            comptime hook_fn: *const fn (*T, Entity, *World) EcsError!void,
        ) EcsError!void {
            try self.hooks.OnRemoveComp(self.memtator.world(), T, hook_fn);
        }

        /// add a system
        /// accepts single function or tuple of function.
        pub fn addSystem(self: *World, schedule: anytype, comptime func: anytype) !void {
            try self.systems.add(self.memtator.world(), schedule, func, null);
        }

        /// add a system with a run time condition
        /// accepts single function or tuple of functions.
        pub fn addSystemEx(self: *World, schedule: anytype, comptime run_fn: anytype, comptime condition_fn: SystemRegistry.ConditionFn) !void {
            try self.systems.add(self.memtator.world(), schedule, run_fn, condition_fn);
        }

        ///! get a resource
        pub fn resource(self: *const World, comptime R: type) EcsError!*R {
            return self.resources.get(R) orelse return EcsError.ResourceNotFound;
        }

        /// get a resource by type
        pub fn getResource(self: *const World, comptime R: type) EcsError!*R {
            return self.resources.get(R) orelse return EcsError.ResourceNotFound;
        }

        /// get a resource by type
        /// creates a default impl of the type and returns it. Type must have defaults!
        pub fn getOrDefaultResource(self: *World, comptime R: type) EcsError!*R {
            return try self.resources.getOrDefault(self.memtator.world(), R);
        }

        /// update tick
        /// runs all remainig commands and resets the frame arena
        pub fn update(self: *World) void {
            self.flushCommands() catch |err| {
                std.log.err("command failure with `{any}`", .{err});
            };

            _ = self.memtator.resetFrame();
            self.world_tick = self.world_tick +% 1;
        }

        /// flush the command queue
        /// not thread safe. Should be called between scheduels
        pub fn flushCommands(self: *World) EcsError!void {
            try self.commands.runAllUnsafe(self);
        }

        fn despawn_with_children(self: *World, ent: Entity) EcsError!void {

            // ----------------------------------------
            // hook
            const mask = self.archtypes.mask_lookup.get(ent).?;
            const hook_mask = mask.intersectWith(self.hooks.has_despawn_hook);
            var it = hook_mask.iterator();
            while (it.next()) |flag| {
                const ptr = self.archtypes.getSingleOpaque(ent, flag).?;
                try self.hooks.runDespawnHook(flag, ptr, ent, self);
            }
            // ----------------------------------------

            // despawn children
            if (self.archtypes.getSingle(ent, Children)) |children| {
                for (children.items.items) |child| {
                    try self.despawn_with_children(child);
                }

                children.deinit(self.memtator.world());
            }

            try self.archtypes.despawn(self.memtator.world(), ent);
        }

        fn despawn(self: *World, ent: Entity) EcsError!void {
            if (!self.isValid(ent)) return;
            // remove from parent children
            if (self.archtypes.getSingle(ent, Parent)) |parent| {
                if (self.archtypes.getSingle(parent.entity, Children)) |children| {
                    var index: ?usize = null;
                    for (children.items.items, 0..) |child, i| {
                        if (child == ent) index = i;
                    }
                    if (index) |i| _ = children.items.swapRemove(i);
                }
            }

            try self.despawn_with_children(ent);
            try self.entities.unused.append(self.memtator.world(), ent);
        }

        /// total used entities
        pub fn entityCount(self: *World) usize {
            return @intCast(self.archtypes.entity_lookup.size);
        }

        /// add a plugin. Any struct that implements a `plugin(app:*App) !void` is considered a plugin.
        pub fn addPlugin(self: *World, mod: type) !void {
            try mod.plugin(self);
        }

        /// threadsafe next entity id
        pub fn nextEntityId(self: *World) Entity {
            self.entities.entity_mutex.lock();
            defer self.entities.entity_mutex.unlock();

            if (self.entities.unused.items.len > 0) {
                var ent = self.entities.unused.pop().?;
                ent.incGen();
                return ent;
            } else {
                const ent = Entity.new(self.entities.count);
                self.entities.count += 1;
                return ent;
            }
        }

        ///TODO: move
        const BatchExecutor = Executor(.{ .max_threads = desc.thread_count });

        /// main system scheduler
        pub const SystemRegistry = struct {
            const Self = @This();
            const LocalRegistry = ResourceRegistry;
            pub const ConditionFn = *const fn (*World, *LocalRegistry) EcsError!bool;
            pub const SystemFn = *const fn (*anyopaque, *World, *LocalRegistry, u32) EcsError!void;
            pub const SystemID = struct { slot: usize };
            const ScheduleID = u32;
            /// a system's mem represntation
            pub const OpaqueSystem = struct {
                //----------
                // TODO: replace with access
                // read_mask: ComponentMask,
                // write_mask: ComponentMask,
                access: Access,
                //----------
                ptr: *anyopaque,
                run: SystemRegistry.SystemFn,
                condition: ?SystemRegistry.ConditionFn = null,
                debug: []u8,
                locals: LocalRegistry = .{},
                run_time_ns: i128 = 0,
                batch_id: usize = 0,
                last_run_tick: u32 = 0,
            };

            pub const Schedule = struct {
                systems: std.ArrayList(struct {
                    id: SystemID,
                    deps: ?std.ArrayList(SystemID) = null,
                }) = .{},
                batch_count: usize = 0,
                run_time_ns: i128 = 0,
            };

            // --------------------------
            executor: BatchExecutor = undefined,
            // pool: std.Thread.Pool = undefined,
            systems: std.ArrayList(OpaqueSystem) = .{},
            system_ptr_lookup: std.AutoHashMapUnmanaged(usize, SystemID) = .{},
            schedule_order: std.AutoHashMapUnmanaged(ScheduleID, Schedule) = .{},
            // --------------------------

            pub fn init(self: *Self, gpa: std.mem.Allocator) !void {
                self.executor = BatchExecutor.init(gpa);
                try self.executor.start();
            }

            /// free all registered systems, leaky, debug only idc
            pub fn clear(self: *Self, gpa: std.mem.Allocator) void {
                _ = gpa; // autofix
                self.systems.clearRetainingCapacity();
                self.schedule_order.clearRetainingCapacity();
                self.system_ptr_lookup.clearRetainingCapacity();
            }

            pub fn getScheduleTime(self: *SystemRegistry, schedule: anytype) i128 {
                comptime {
                    if (@typeInfo(@TypeOf(schedule)) != .@"enum") @compileError("schedule needs to be of type enum");
                }
                var sum = @as(i128, 0);
                if (self.systems.get(@intFromEnum(schedule))) |set| {
                    for (set.items) |sys| {
                        sum += sys.last_run_time_ns;
                    }
                }

                return sum;
            }

            /// Extracting the original function path from the return type.
            /// highly illegal function, thx Zig!
            inline fn extractFnName(comptime func: anytype) []const u8 {
                if (!@inComptime()) @compileError("lol");
                const fn_type = @typeInfo(@TypeOf(func)).pointer.child;
                const info = @typeInfo(fn_type);
                const ret_str: []const u8 = @typeName(info.@"fn".return_type.?);

                return comptime blk: {
                    if (ret_str.len <= 28) {
                        break :blk "anonym";
                    }

                    const fstr = ret_str[28..]; // constrained by system signature, won't move
                    var c: u32 = 0;
                    while (fstr[c] != ')') {
                        c += 1;
                    }
                    break :blk fstr[0..c];
                };
            }

            const ScheduleStats = struct {
                pub const InfoEntry = struct {
                    batch_id: usize,
                    name: []u8,
                    avg_ns: i128,
                };
                avg_ns: i128 = 0,
                batch_count: usize = 0,
                batches: std.ArrayList(InfoEntry) = .{},
            };

            pub fn scheduleInfo(self: *const Self, gpa: std.mem.Allocator, schedule: anytype) !ScheduleStats {
                const set: *Schedule = self.schedule_order.getPtr(@intFromEnum(schedule)) orelse return error.NotFound;
                var info = ScheduleStats{};

                for (set.systems.items) |*en| {
                    const sys = &self.systems.items[en.id.slot];
                    try info.batches.append(gpa, .{
                        .batch_id = sys.batch_id,
                        .name = sys.debug,
                        .avg_ns = sys.run_time_ns,
                    });
                }

                info.batch_count = set.batch_count;
                info.avg_ns = set.run_time_ns;
                return info;
            }

            fn putSystem(
                self: *Self,
                gpa: std.mem.Allocator,
                comptime system: anytype,
                comptime condition_fn: ?ConditionFn,
            ) EcsError!SystemID {
                const func = system;
                const fn_name = comptime extractFnName(func);

                if (@typeInfo(@TypeOf(func)) != .pointer) @compileError(cprint("system needs to be pointer in `{s}`", .{fn_name}));
                if (@typeInfo(@typeInfo(@TypeOf(func)).pointer.child) != .@"fn") @compileError(cprint("system needs to be pointer `{s}`", .{fn_name}));

                const fnType = @typeInfo(@TypeOf(func)).pointer.child;
                const info = @typeInfo(fnType);

                var access: Access = .{};
                inline for (info.@"fn".params) |*p| {
                    const PT = p.type.?;
                    if (@typeInfo(PT) != .@"struct") @compileError(cprint("System param must be struct with method `fromWorld(w:*World)Self` in `{s}::{s}`\n", .{ fn_name, @typeName(p.type.?) }));

                    if (@hasDecl(PT, "addAccess")) {
                        PT.addAccess(&access);
                    }
                }

                const op_system = OpaqueSystem{
                    .ptr = @constCast(func),
                    .access = access,
                    .condition = condition_fn,
                    .debug = try std.fmt.allocPrint(gpa, "{s}", .{fn_name}),
                    .run = (struct {
                        fn run(ptr: *anyopaque, world: *World, locals: *LocalRegistry, last_run_tick: u32) EcsError!void {
                            const sys_func: *fnType = @ptrCast(@alignCast(ptr));
                            var sys_args: genArgType(info.@"fn".params) = undefined;
                            inline for (info.@"fn".params, 0..) |*p, i| {
                                const PT = switch (@typeInfo(p.type.?)) {
                                    .@"struct" => p.type.?,
                                    else => @compileError("not a valid system param type, needs to be a struct"),
                                };

                                if (@hasDecl(PT, "fromLocal")) {
                                    @field(sys_args, cprint("{d}", .{i})) = try PT.fromLocal(world, locals);
                                    continue;
                                }

                                if (@hasDecl(PT, "fromWorld")) {
                                    var ret = try PT.fromWorld(world);
                                    if (@hasDecl(PT, "setWorldTick")) ret.setWorldTick(last_run_tick);
                                    @field(sys_args, cprint("{d}", .{i})) = ret;
                                    continue;
                                }

                                if (@hasDecl(PT, "is_local_marker")) {
                                    const res = try locals.getOrDefault(world.memtator.world(), PT.innerType);
                                    @field(sys_args, cprint("{d}", .{i})) = PT{ .inner = res };
                                    continue;
                                }

                                @compileError(cprint("system param does not implement fromWorld! (fn(world:*App)Self)  `{s}::{s}`\n", .{ fn_name, @typeName(p.type.?) }));
                            }

                            try @call(.auto, sys_func, sys_args);
                        }
                    }).run,
                };

                try self.systems.append(gpa, op_system);
                const id = SystemID{ .slot = self.systems.items.len - 1 };
                // try self.system_ptr_lookup.put(@intFromPtr(system), id);
                return id;
            }

            pub fn add(
                self: *Self,
                gpa: std.mem.Allocator,
                schedule: anytype,
                comptime system: anytype,
                comptime condition_fn: ?ConditionFn,
            ) EcsError!void {
                const set = try self.schedule_order.getOrPut(gpa, @intFromEnum(schedule));
                if (!set.found_existing) set.value_ptr.* = .{};

                const SystemType = @TypeOf(system);
                const info = @typeInfo(SystemType);

                switch (info) {
                    .@"struct" => |_struct| {
                        if (!_struct.is_tuple) @compileLog("system must be tuple");
                        inline for (system) |func| {
                            const id = try self.putSystem(gpa, func, condition_fn);
                            try set.value_ptr.systems.append(gpa, .{ .id = id });
                        }
                    },
                    .type => {
                        // chain
                        if (@hasDecl(system, "_is_chain")) {
                            var deps = std.ArrayList(SystemID){};
                            inline for (system.inner) |field| {
                                const field_ty = @TypeOf(field);
                                switch (@typeInfo(field_ty)) {
                                    .@"struct" => |_struct| {
                                        if (!_struct.is_tuple) @compileLog("only pointers and tuples allowed in chains");
                                        // add group with same deps
                                        const tuple_deps = try deps.clone(gpa);
                                        inline for (field) |func| {
                                            const id = try self.putSystem(gpa, func, condition_fn);
                                            try set.value_ptr.systems.append(gpa, .{
                                                .id = id,
                                                .deps = tuple_deps,
                                            });

                                            try deps.append(gpa, id);
                                        }
                                    },
                                    else => {
                                        const id = try self.putSystem(gpa, field, condition_fn);
                                        try set.value_ptr.systems.append(gpa, .{
                                            .id = id,
                                            .deps = if (deps.items.len > 0) try deps.clone(gpa) else null,
                                        });

                                        try deps.append(gpa, id);
                                    },
                                }
                            }
                        }
                    },
                    else => {
                        const id = try self.putSystem(gpa, system, condition_fn);
                        try set.value_ptr.systems.append(gpa, .{ .id = id });
                    },
                }
            }

            fn genArgType(comptime fnargs: []const std.builtin.Type.Fn.Param) type {
                var fields: [fnargs.len]std.builtin.Type.StructField = undefined;
                for (fnargs, 0..) |*p, i| {
                    fields[i] = std.builtin.Type.StructField{
                        .type = p.type.?,
                        .alignment = @alignOf(p.type.?),
                        .is_comptime = false,
                        .default_value_ptr = null,
                        .name = std.fmt.comptimePrint("{d}", .{i}),
                    };
                }
                return @Type(.{
                    .@"struct" = .{
                        .layout = .auto,
                        .fields = &fields,
                        .decls = &[_]std.builtin.Type.Declaration{},
                        .is_tuple = true,
                    },
                });
            }

            pub fn run(self: *Self, schedule: anytype, world: *World) !void {
                if (@typeInfo(@TypeOf(schedule)) != .@"enum") @compileError("schedule needs to be of type enum");

                const set = self.schedule_order.getPtr(@intFromEnum(schedule)) orelse return;

                const gpa = world.memtator.frame();
                var scheduled_systems = try std.ArrayList(SystemID).initCapacity(gpa, 32);
                var dep_graph = std.AutoHashMap(SystemID, std.ArrayList(SystemID)).init(gpa);
                var dep_counter = std.AutoHashMap(SystemID, usize).init(gpa);

                const start = std.time.nanoTimestamp();

                for (set.systems.items) |entry| {
                    const sys = &self.systems.items[entry.id.slot];
                    if (sys.condition) |con| {
                        const should_run = con(world, &sys.locals) catch {
                            return EcsError.SystemConditionFailure;
                        };

                        if (!should_run) continue;
                    }
                    try scheduled_systems.append(gpa, entry.id);
                    if (entry.deps) |deps| {
                        try dep_counter.put(entry.id, deps.items.len);
                        for (deps.items) |dep_id| {
                            const res = try dep_graph.getOrPut(dep_id);
                            if (!res.found_existing) res.value_ptr.* = .{};
                            try res.value_ptr.append(gpa, entry.id);
                        }
                    }
                }

                while (scheduled_systems.items.len > 0) {
                    var remove_list = std.ArrayList(usize){};
                    for (scheduled_systems.items, 0..) |id, index| {
                        if (dep_counter.get(id)) |count| if (count > 0) continue;

                        const sys = &self.systems.items[id.slot];
                        executeSystem(sys, world, 0);

                        try remove_list.append(gpa, index);
                        if (dep_graph.getPtr(id)) |deps| {
                            for (deps.items) |dep_id| {
                                //reduce dep counter
                                if (dep_counter.getPtr(dep_id)) |count| count.* = count.* - 1;
                            }
                        }
                    }

                    for (remove_list.items, 0..) |index, c| {
                        _ = scheduled_systems.orderedRemove(index - c);
                    }
                }

                const total = std.time.nanoTimestamp() - start;
                set.run_time_ns = @divTrunc(set.run_time_ns + total, 2);
                set.batch_count = 0;
            }

            pub fn runPar(self: *Self, schedule: anytype, world: *World) !void {
                const set = self.schedule_order.getPtr(@intFromEnum(schedule)) orelse return;
                const start = std.time.nanoTimestamp();
                const gpa = world.memtator.frame();
                // Optimized queue entry with dependency tracking
                const QueueEntry = struct {
                    id: SystemID,
                    access: Access,
                };

                // Multi-container architecture for efficient scheduling
                var scheduled_systems = try std.ArrayList(QueueEntry).initCapacity(gpa, 32);
                var batches = try std.ArrayList(std.ArrayList(SystemID)).initCapacity(gpa, 32);
                var dep_graph = std.AutoHashMap(SystemID, std.ArrayList(SystemID)).init(gpa);
                var dep_counter = std.AutoHashMap(SystemID, usize).init(gpa);

                // prep running system
                for (set.systems.items) |entry| {
                    const sys = &self.systems.items[entry.id.slot];
                    if (sys.condition) |con| {
                        const should_run = con(world, &sys.locals) catch {
                            return EcsError.SystemConditionFailure;
                        };

                        if (!should_run) continue;
                    }

                    try scheduled_systems.append(gpa, .{
                        .id = entry.id,
                        .access = sys.access,
                    });

                    if (entry.deps) |deps| {
                        try dep_counter.put(entry.id, deps.items.len);
                        for (deps.items) |dep_id| {
                            const res = try dep_graph.getOrPut(dep_id);
                            if (!res.found_existing) res.value_ptr.* = .{};
                            try res.value_ptr.append(gpa, entry.id);
                        }
                    }
                }

                // prep batches
                while (scheduled_systems.items.len > 0) {
                    var batch = std.ArrayList(SystemID){};
                    var access = Access{};

                    var remove_list = std.ArrayList(usize){};
                    var update_deps = std.ArrayList(SystemID){};

                    for (scheduled_systems.items, 0..) |en, index| {
                        if (dep_counter.get(en.id)) |count| if (count > 0) continue;

                        if (!access.isCompatible(&en.access)) continue;

                        batch.append(gpa, en.id) catch break;
                        access.merge(&en.access);

                        try remove_list.append(gpa, index);
                        try update_deps.append(gpa, en.id);
                    }

                    for (update_deps.items) |id| {
                        if (dep_graph.getPtr(id)) |deps| {
                            for (deps.items) |dep_id| {
                                if (dep_counter.getPtr(dep_id)) |count| count.* = count.* - 1;
                            }
                        }
                    }

                    update_deps.clearRetainingCapacity();

                    for (remove_list.items, 0..) |index, c| {
                        _ = scheduled_systems.orderedRemove(index - c);
                    }

                    try batches.append(gpa, batch);
                }

                for (batches.items, 0..) |batch, i| {
                    var wg = std.Thread.WaitGroup{};
                    for (batch.items) |id| {
                        const sys = &self.systems.items[id.slot];
                        try self.executor.run(&wg, executeSystem, .{ sys, world, i });
                    }
                    wg.wait();
                }

                const total = std.time.nanoTimestamp() - start;
                set.run_time_ns = @divTrunc(set.run_time_ns + total, 2);
                set.batch_count = batches.items.len;
            }

            fn executeSystem(sys: *OpaqueSystem, world: *World, batch_id: usize) void {
                const start = std.time.nanoTimestamp();

                sys.run(sys.ptr, world, &sys.locals, sys.last_run_tick) catch |err| {
                    std.debug.print("system failed with: `{any}` @`{s}`\n", .{ err, sys.debug });
                };

                const total = std.time.nanoTimestamp() - start;
                sys.run_time_ns = @divTrunc(sys.run_time_ns + total, 2);
                sys.batch_id = batch_id;
                sys.last_run_tick = world.world_tick;
            }
        };

        pub fn And(
            comptime asys: SystemRegistry.ConditionFn,
            comptime bsys: SystemRegistry.ConditionFn,
        ) SystemRegistry.ConditionFn {
            return (struct {
                fn and_con(world: *World, locals: *ResourceRegistry) EcsError!bool {
                    const a = try asys(world, locals);
                    const b = try bsys(world, locals);
                    return a and b;
                }
            }).and_con;
        }

        pub fn Or(
            comptime asys: SystemRegistry.ConditionFn,
            comptime bsys: SystemRegistry.ConditionFn,
        ) SystemRegistry.ConditionFn {
            return (struct {
                fn or_cond(world: *World, locals: *ResourceRegistry) EcsError!bool {
                    const a = try asys(world, locals);
                    const b = try bsys(world, locals);
                    return a or b;
                }
            }).or_cond;
        }

        pub fn Res(comptime R: type) type {
            return struct {
                const Self = @This();
                const _read = [1]u32{hashType(R)};
                inner: *const R = undefined,

                fn fromWorld(world: *const World) EcsError!Self {
                    var self = Self{};
                    self.inner = try world.resource(R);
                    return self;
                }

                pub fn addAccess(access: *Access) void {
                    const flag = ResFlag.getFlag(R);
                    access.res_read_write.insert(flag);
                }
            };
        }

        pub fn ResMut(comptime R: type) type {
            return struct {
                const Self = @This();
                const _read = [1]u32{hashType(R)};
                const _write = _read;
                inner: *R = undefined,
                fn fromWorld(world: *World) EcsError!Self {
                    var self = Self{};
                    self.inner = try world.resource(R);
                    return self;
                }

                pub fn addAccess(access: *Access) void {
                    const flag = ResFlag.getFlag(R);
                    access.res_write.insert(flag);
                    access.res_read_write.insert(flag);
                }
            };
        }

        // --------------------------------------
        // Jobs pool
        // --------------------------------------
        pub const Jobs = struct {
            const Self = @This();
            executor: *BatchExecutor,

            fn fromWorld(world: *World) EcsError!Self {
                return Jobs{
                    .executor = &world.systems.executor,
                };
            }

            pub fn go(self: *const Self, group: *std.Thread.WaitGroup, comptime func: anytype, args: anytype) EcsError!void {
                try self.executor.run(group, func, args);
            }
        };

        // --------------------------------------
        // Allocation
        // --------------------------------------
        pub const Alloc = struct {
            frame: std.mem.Allocator,
            world: std.mem.Allocator,

            fn fromWorld(world: *World) EcsError!Alloc {
                return .{
                    .frame = world.memtator.frame(),
                    .world = world.memtator.world(),
                };
            }
        };

        // --------------------------------------
        // commands
        // --------------------------------------
        pub const Commands = struct {
            const Self = @This();
            reg: *CommandRegistry,

            /// # Frame Allocator
            /// Arena bound to the lifetime of a single update frame. Leak everything!
            frame_gpa: std.mem.Allocator,

            /// # World Allocator
            /// Arena bound to the liftime of the app.
            world_gpa: std.mem.Allocator,

            /// # Raw World
            /// Unsafe world access.
            world: *World,

            /// checks if the entity is still valid
            pub fn entityValid(self: *const Self, ent: Entity) bool {
                return self.world.isValid(ent);
            }

            /// spawn something new
            /// any tuple in the bundle is spawned as a child
            pub fn spawn(self: *const Self, bundle: anytype) EcsError!Entity {
                const entity = self.world.nextEntityId();
                const cmd = try insertCommand(self.frame_gpa, entity, bundle);
                try self.reg.add(self.frame_gpa, cmd);
                return entity;
            }

            pub fn despawn(self: *const Self, entity: Entity) EcsError!void {
                const cmd = try despawnCommand(self.frame_gpa, entity);
                try self.reg.add(self.frame_gpa, cmd);
            }

            pub fn remove(self: *const Self, entity: Entity, comptime C: type) EcsError!void {
                const cmd = try removeCommand(self.frame_gpa, entity, C);
                try self.reg.add(self.frame_gpa, cmd);
            }

            pub fn add(self: *const Self, cmd: Command) EcsError!void {
                try self.reg.add(self.frame_gpa, cmd);
            }

            pub fn insert(self: *const Self, entity: Entity, comp: anytype) EcsError!void {
                const cmd = try insertCommand(self.frame_gpa, entity, comp);
                try self.reg.add(self.frame_gpa, cmd);
            }

            pub fn insertResource(self: *const Self, comp: anytype) EcsError!void {
                const cmd = try insertResourceCommand(self.frame_gpa, comp);
                try self.reg.add(self.frame_gpa, cmd);
            }

            pub fn removeResource(self: *const Self, comp: anytype) EcsError!void {
                const cmd = try removeResourceCommand(self.frame_gpa, comp);
                try self.reg.add(self.frame_gpa, cmd);
            }

            pub fn addChild(self: *const Self, parent: Entity, child: Entity) EcsError!void {
                const cmd = try addChildCommand(self.frame_gpa, parent, child);
                try self.reg.add(self.frame_gpa, cmd);
            }

            pub fn fromWorld(world: *World) EcsError!Self {
                return Self{
                    .reg = &world.commands,
                    .world = world,
                    .world_gpa = world.memtator.world(),
                    .frame_gpa = world.memtator.frame(),
                };
            }
        };

        pub const CommandRegistry = struct {
            const Self = @This();

            mutex: std.Thread.Mutex = .{},
            queue: std.ArrayList(Command) = .{},

            pub fn add(self: *Self, allocator: std.mem.Allocator, cmd: Command) EcsError!void {
                self.mutex.lock();
                defer self.mutex.unlock();

                try self.queue.append(allocator, cmd);
            }

            pub fn runAllUnsafe(self: *Self, world: *World) !void {
                for (self.queue.items) |cmd| {
                    try cmd.run(cmd.ptr, world);
                }

                self.queue = .{};
            }
        };

        fn removeResourceCommand(comptime R: type) EcsError!Command {
            return Command{
                .ptr = undefined,
                .run = (struct {
                    fn run(_: *anyopaque, world: *World) EcsError!void {
                        try world.resources.remove(world.memtator.world(), R);
                    }
                }).run,
            };
        }

        fn addChildCommand(allocator: std.mem.Allocator, parent: Entity, child: Entity) EcsError!Command {
            const Args = struct {
                parent: Entity,
                child: Entity,
            };

            var arg_ptr = try allocator.create(Args);
            arg_ptr.parent = parent;
            arg_ptr.child = child;

            return Command{
                .ptr = undefined,
                .run = (struct {
                    fn run(ctx: *anyopaque, world: *World) EcsError!void {
                        const gpa = world.memtator.world();
                        const args: *Args = @ptrCast(@alignCast(ctx));

                        if (world.archtypes.getSingle(args.parent, Children)) |c| {
                            try c.items.append(gpa, args.child);
                        } else {
                            var c = Children{};
                            try c.items.append(gpa, args.child);
                            try world.archtypes.add(gpa, world.world_tick, args.parent, c);
                        }

                        try world.archtypes.add(gpa, world.world_tick, args.child, Parent{ .entity = args.parent });
                    }
                }).run,
            };
        }

        fn insertResourceCommand(allocator: std.mem.Allocator, res: anytype) EcsError!Command {
            const ResourceType = @TypeOf(res);
            const ptr = try allocator.create(ResourceType);
            ptr.* = res;

            return Command{
                .ptr = ptr,
                .run = (struct {
                    fn run(ctx: *anyopaque, world: *World) EcsError!void {
                        const res_ptr: *ResourceType = @ptrCast(@alignCast(ctx));
                        try world.addResource(res_ptr.*);
                    }
                }).run,
            };
        }

        fn despawnCommand(allocator: std.mem.Allocator, entity: Entity) EcsError!Command {
            const ptr = try allocator.create(Entity);
            ptr.* = entity;

            return Command{
                .ptr = ptr,
                .run = (struct {
                    fn run(ctx: *anyopaque, world: *World) EcsError!void {
                        const ent: *Entity = @ptrCast(@alignCast(ctx));
                        try world.despawn(ent.*);
                    }
                }).run,
            };
        }

        fn removeCommand(allocator: std.mem.Allocator, entity: Entity, comptime C: type) EcsError!Command {
            const ptr = try allocator.create(Entity);
            ptr.* = entity;

            return Command{
                .ptr = ptr,
                .run = (struct {
                    fn run(ctx: *anyopaque, world: *World) EcsError!void {
                        const ent: *Entity = @ptrCast(@alignCast(ctx));
                        if (world.isValid(ent.*)) {
                            const flag = CompFlag.getFlag(C);

                            if (world.hooks.remove_hooks.contains(flag)) {
                                const comp = world.archtypes.getSingle(ent.*, C).?;
                                try world.hooks.runRemoveHook(flag, comp, ent.*, world);
                            }

                            try world.archtypes.remove(world.memtator.world(), ent.*, C);
                        }
                    }
                }).run,
            };
        }

        fn insertCommand(allocator: std.mem.Allocator, entity: Entity, bundle: anytype) EcsError!Command {
            if (@typeInfo(@TypeOf(bundle)) != .@"struct") @compileError("a bundle must be a tuple struct of components");

            const ArgType = @TypeOf(bundle);
            const Args = struct {
                ent: Entity,
                bundle: ArgType,
            };

            var arg_ptr = try allocator.create(Args);
            arg_ptr.bundle = bundle;
            arg_ptr.ent = entity;

            return Command{
                .ptr = arg_ptr,
                .run = (struct {
                    fn run(ctx: *anyopaque, world: *World) EcsError!void {
                        const gpa = world.memtator.world();
                        const args: *Args = @ptrCast(@alignCast(ctx));

                        if (!isTuple(ArgType)) {
                            const flag = CompFlag.getFlag(@TypeOf(bundle));
                            try world.hooks.runAddedHook(flag, &args.bundle, args.ent, world);
                            try world.archtypes.add(world.memtator.world(), world.world_tick, args.ent, args.bundle);
                            return;
                        }

                        inline for (args.bundle, 0..) |comp, i| {
                            const CompType: type = @TypeOf(comp);
                            // ---------------------
                            // spawn children
                            if (isTuple(CompType)) {
                                const child_ent = world.nextEntityId();
                                const cmp = try insertCommand(world.memtator.frame(), child_ent, comp);
                                try cmp.run(cmp.ptr, world);

                                if (world.archtypes.getSingle(args.ent, Children)) |c| {
                                    try c.items.append(gpa, child_ent);
                                } else {
                                    var c = Children{};
                                    try c.items.append(gpa, child_ent);
                                    try world.archtypes.add(world.memtator.world(), world.world_tick, args.ent, c);
                                }

                                try world.archtypes.add(world.memtator.world(), world.world_tick, child_ent, Parent{ .entity = args.ent });
                            } else {
                                const info = @typeInfo(ArgType);
                                if (!info.@"struct".fields[i].is_comptime) {
                                    const flag = CompFlag.getFlag(CompType);
                                    try world.hooks.runAddedHook(flag, &args.bundle[i], args.ent, world);
                                }
                            }
                            // ---------------------
                        }

                        try world.archtypes.addBundle(world.memtator.world(), world.world_tick, args.ent, args.bundle);
                    }
                }).run,
            };
        }

        const Command = struct {
            ptr: *anyopaque,
            run: *const fn (ctx: *anyopaque, world: *World) EcsError!void,
        };

        pub fn Query(query: anytype) type {
            return IQueryFiltered(desc, query, .{});
        }

        pub fn QueryFiltered(query: anytype, filter: anytype) type {
            return IQueryFiltered(desc, query, filter);
        }
    };
}

pub fn Local(comptime T: type) type {
    return struct {
        const is_local_marker: bool = true;
        const innerType = T;
        inner: *T = undefined,
    };
}

pub fn Mut(comptime T: type) type {
    return struct {
        const _is_mut: bool = true;
        const inner = T;
    };
}

/// # expects tuple. Systems run in order. Tuple in tuple run in par!
pub fn Chain(comptime T: anytype) type {
    const ty = @TypeOf(T);
    if (!isTuple(ty)) @compileLog("`Chain` expects a tuple");

    return struct {
        pub const _is_chain: bool = true;
        const inner: @TypeOf(T) = T;
    };
}

/// # values you triggered `changed` on in the since last system run.
/// You have to manually poll `iter.changed(type)` on query iterations for `changed` to be active.
/// sry, derefMut traits in zig are very ugly/boiler heavy.
pub fn Changed(comptime C: type) type {
    return struct {
        const inner = C;
        const _is_changed: bool = true;
    };
}

/// # Comp that was added since last system run
pub fn Added(comptime C: type) type {
    return struct {
        const inner = C;
        const _is_added: bool = true;
    };
}

/// # simple with filter
pub fn With(comptime C: type) type {
    return struct {
        const inner = C;
        const _is_with: bool = true;
    };
}

/// # simple without filter
pub fn WithOut(comptime C: type) type {
    return struct {
        const inner = C;
        const _is_without: bool = true;
    };
}

pub inline fn hashType(comptime T: type) u32 {
    var value: u32 = 2166136261;
    for (@typeName(T)) |c| value = (value ^ @as(u32, @intCast(c))) *% 16777619;
    return value;
}

pub inline fn isTuple(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |s| return s.is_tuple,
        else => return false,
    }
}

// ---------------------------------------
// resource
// ---------------------------------------
pub const ResourceRegistry = struct {
    const ResID = u32;
    const TypeID = u32;
    const Self = @This();

    data: std.AutoHashMapUnmanaged(TypeID, Resource) = .{},

    pub fn deinit(self: *Self, gpa: std.mem.Allocator) void {
        var it = self.data.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(entry.value_ptr.ctx, gpa);
        self.data.deinit(gpa);
    }

    pub fn get(self: *const Self, comptime T: type) ?*T {
        const hash = hashType(T);
        const res = self.data.get(hash) orelse return null;
        return Resource.cast(res.ctx, T);
    }

    pub fn getOrDefault(self: *Self, gpa: std.mem.Allocator, comptime T: type) !*T {
        const hash = hashType(T);
        const entry = try self.data.getOrPut(gpa, hash);
        if (!entry.found_existing) entry.value_ptr.* = Resource.init(T{}, gpa);
        return Resource.cast(entry.value_ptr.ctx, T);
    }

    pub fn remove(self: *Self, gpa: std.mem.Allocator, comptime R: type) !void {
        const hash = hashType(R);
        const entry = self.data.fetchRemove(hash) orelse return;
        entry.value.deinit(entry.value.ctx, gpa);
    }

    pub fn register(self: *Self, gpa: std.mem.Allocator, resource: anytype) !void {
        const ResType = @TypeOf(resource);
        const hash = hashType(ResType);
        const entry = try self.data.getOrPut(gpa, hash);
        if (entry.found_existing) {
            entry.value_ptr.deinit(entry.value_ptr.ctx, gpa);
        }
        entry.value_ptr.* = Resource.init(resource, gpa);
    }
};

const Resource = struct {
    ctx: *anyopaque,
    deinit: *const fn (ptr: *anyopaque, alloc: std.mem.Allocator) void,

    pub fn cast(ptr: *anyopaque, comptime T: type) *T {
        return @ptrCast(@alignCast(ptr));
    }

    pub fn init(res: anytype, alloc: std.mem.Allocator) Resource {
        const ptr = alloc.create(@TypeOf(res)) catch @panic("oom");
        ptr.* = res;
        return Resource{
            .ctx = ptr,
            .deinit = (struct {
                fn deinit(p: *anyopaque, allocator: std.mem.Allocator) void {
                    var r = Resource.cast(p, @TypeOf(res));
                    if (@hasDecl(@TypeOf(res), "deinit")) {
                        r.deinit(allocator);
                    }
                    allocator.destroy(r);
                }
            }).deinit,
        };
    }
};

/// component/resource bit set enum
fn FlagSet(comptime F: type) type {
    return enum(F) {
        const Self = @This();
        pub const max = std.math.maxInt(FlagInt);
        pub const Set = std.enums.EnumSet(CompFlag);
        pub const Info = struct {
            name: []const u8,
            hash: u32,
            size: usize,
            alignment: usize,
            flag: ?CompFlag = null,

            // TODO: breaks dylib, heap mode soon?
            pub inline fn init(comptime T: type) *Self.Info {
                return &struct {
                    var info: Self.Info = .{
                        .name = @typeName(T),
                        .hash = hashType(T),
                        .size = @sizeOf(T),
                        .alignment = @alignOf(T),
                    };
                }.info;
            }
        };
        // ------------------------
        var registered_buf: [max]*Info = undefined;
        var registered_len: usize = 0;
        _,
        // ------------------------
        pub inline fn getFlag(comptime T: type) CompFlag {
            const typeId = CompInfo.init(T);
            return Self.register(typeId);
        }
        pub fn register(id: CompId) CompFlag {
            if (id.flag) |f| {
                @branchHint(.likely);
                return f;
            }

            if (registered_len >= max) {
                @panic("set type overflow, increase component count");
            }

            const flag: CompFlag = @enumFromInt(registered_len);
            id.flag = flag;

            registered_buf[registered_len] = id;
            _ = @atomicRmw(@TypeOf(registered_len), &registered_len, .Add, 1, .release);

            return flag;
        }

        pub fn getId(self: CompFlag) *Info {
            assert(@intFromEnum(self) < registered_len);
            return registered_buf[@intFromEnum(self)];
        }
    };
}

/// TODO: move to AppDesc
/// 128 components & resources limit
const FlagInt = u7;

pub const CompFlag = FlagSet(FlagInt);
pub const CompInfo = CompFlag.Info;
pub const CompId = *CompFlag.Info;

pub const ResFlag = FlagSet(FlagInt);
pub const ResInfo = CompFlag.Info;
pub const ResId = *ResFlag.Info;

/// access flags for lock free concurrency
pub const Access = struct {
    comp_read_write: CompFlag.Set = .{},
    comp_write: CompFlag.Set = .{},
    res_read_write: ResFlag.Set = .{},
    res_write: ResFlag.Set = .{},

    pub fn isCompatible(self: *const Access, lhs: *const Access) bool {
        return self.comp_compatible(lhs) and self.res_compatible(lhs);
    }

    fn merge(self: *Access, lhs: *const Access) void {
        self.comp_read_write.setUnion(lhs.comp_read_write);
        self.comp_write.setUnion(lhs.comp_write);
        self.res_read_write.setUnion(lhs.res_read_write);
        self.res_write.setUnion(lhs.res_write);
    }

    inline fn comp_compatible(self: *const Access, lhs: *const Access) bool {
        const empty = CompFlag.Set.initEmpty();
        if (!self.comp_read_write.intersectWith(lhs.comp_write).eql(empty)) return false;
        if (!self.comp_write.intersectWith(lhs.comp_read_write).eql(empty)) return false;
        if (!self.comp_write.intersectWith(lhs.comp_write).eql(empty)) return false;
        return true;
    }

    inline fn res_compatible(self: *const Access, lhs: *const Access) bool {
        const empty = ResFlag.Set.initEmpty();
        if (!self.res_read_write.intersectWith(lhs.res_write).eql(empty)) return false;
        if (!self.res_write.intersectWith(lhs.res_read_write).eql(empty)) return false;
        if (!self.res_write.intersectWith(lhs.res_write).eql(empty)) return false;
        return true;
    }
};

/// ArchType = opaque runtime MultiArrayList
pub const ArchType = struct {
    const Self = @This();
    const ColMeta = struct {
        flag: CompFlag,
        offset: usize,
        size: usize,
    };
    pub const TickInfo = struct {
        added: u32 = 0,
        changed: u32 = 0,
    };
    /// allocate in chunks of:
    chunk_size: usize = 64,
    mask: CompFlag.Set = CompFlag.Set.initEmpty(),
    /// Archtable layout |XX = pad
    /// |ENTITY-SLICE----|XX|C1-SLICE----------|X|C2-SLICE--------- ..
    /// |ENTITY,ENTITY.. |XX|C1,C1..Tick,Tick..|X|C2,C2..Tick,Tick..
    bytes: []u8 = undefined,
    alignment: usize = 0,
    columns: std.ArrayList(ColMeta) = .{},
    /// entity -> index
    entity_lookup: std.AutoHashMapUnmanaged(Entity, usize) = .{},
    /// comp hash -> comps index
    column_lookup: std.AutoHashMapUnmanaged(CompFlag, usize) = .{},
    len: usize = 0,
    capacity: usize = 0,

    pub fn addComp(self: *Self, gpa: std.mem.Allocator, flag: CompFlag) !void {
        assert(self.len == 0);

        const id = flag.getId();
        const col_meta = ColMeta{
            .size = id.size,
            .flag = flag,
            .offset = 0,
        };

        const typeId = col_meta.flag.getId();

        if (typeId.alignment > self.alignment) self.alignment = typeId.alignment;
        if (self.alignment == 0) self.alignment = 1;

        self.mask.insert(flag);
        try self.columns.append(gpa, col_meta);
        try self.column_lookup.put(gpa, flag, self.columns.items.len - 1);
        self.calcTableOffsets();
    }

    pub fn removeComp(self: *Self, flag: CompFlag) void {
        assert(self.len == 0);
        self.mask.remove(flag);

        const last_comp_meta = self.columns.items[self.columns.items.len - 1];
        const en = self.column_lookup.fetchRemove(flag).?;

        assert(self.columns.items.len > 0);

        // TODO:
        // handle empty archtype case: last comp = removed comp
        // assert(en.key != last_comp_meta_hash);
        // swap remove with last comp
        _ = self.columns.swapRemove(en.value);

        // update last comp lookup
        if (en.key != last_comp_meta.flag) {
            const lookup_entry = self.column_lookup.getPtr(last_comp_meta.flag).?;
            lookup_entry.* = en.value;
        }

        self.calcTableOffsets();
    }

    pub fn remove(self: *Self, gpa: std.mem.Allocator, entity: Entity) !void {
        assert(self.len > 0);

        // remove entity from lookup
        const en = self.entity_lookup.fetchRemove(entity) orelse return EcsError.EntityNotFound;
        assert(en.value < self.len);

        defer self.len -= 1;

        if (en.value == self.len - 1) return;

        // Get the entity that will be moved from the last position
        const moved_entity = self.getEntity(self.len - 1);

        // swap remove entity + components
        self.swapRemoveEntitiy(en.value);
        for (self.columns.items) |*meta| {
            self.swapRemoveComp(en.value, meta);
        }

        // Update the entity lookup for the moved entity
        try self.entity_lookup.put(gpa, moved_entity, en.value);
    }

    pub fn put(self: *Self, gpa: std.mem.Allocator, tick: u32, entity: Entity, bundle: anytype) !void {
        if (self.len >= self.capacity) {
            try self.setCapacity(gpa, self.capacity + self.chunk_size);
        }

        var is_new = false;
        const index: usize = blk: {
            const res = try self.entity_lookup.getOrPut(gpa, entity);
            if (res.found_existing) break :blk res.value_ptr.*;

            res.value_ptr.* = self.len;
            const offset = @sizeOf(Entity) * self.len;
            @memcpy(self.bytes[offset .. offset + @sizeOf(Entity)], std.mem.asBytes(&entity));

            is_new = true;
            self.len += 1;
            errdefer self.len -= 1;
            break :blk res.value_ptr.*;
        };

        assert(self.capacity > index);

        inline for (bundle) |comp| {

            // skip tuples, tuple = child entity
            if (isTuple(@TypeOf(comp))) continue;

            // TODO: maybe should not create new entries?
            const flag = CompFlag.getFlag(@TypeOf(comp));
            const meta = self.getMeta(flag).?;

            self.putRaw(tick, tick, index, meta, std.mem.asBytes(&comp));
        }
    }

    pub inline fn putRaw(self: *Self, changed_tick: u32, added_tick: u32, index: usize, meta: *const ColMeta, bytes: []const u8) void {
        assert(self.capacity >= index);
        const comp_offset = meta.offset + meta.size * index;
        @memcpy(self.bytes[comp_offset .. comp_offset + meta.size], bytes);
        const tick_offset = meta.offset + meta.size * self.capacity + @sizeOf(TickInfo) * index;
        @memcpy(self.bytes[tick_offset .. tick_offset + @sizeOf(TickInfo)], std.mem.asBytes(&TickInfo{
            .added = added_tick,
            .changed = changed_tick,
        }));
    }

    pub inline fn putSingle(self: *Self, gpa: std.mem.Allocator, tick: u32, entity: Entity, comp: anytype) EcsError!void {
        if (self.len >= self.capacity) {
            try self.setCapacity(gpa, self.capacity + self.chunk_size);
        }

        const index = try self.putEntity(gpa, entity);
        assert(self.capacity >= index);

        const flag = CompFlag.getFlag(@TypeOf(comp));
        const meta = self.getMeta(flag).?;
        const bytes: []const u8 = @alignCast(std.mem.asBytes(&comp));
        self.putRaw(tick, tick, index, meta, bytes);
    }

    pub inline fn putEntity(self: *Self, gpa: std.mem.Allocator, entity: Entity) EcsError!usize {
        const res = try self.entity_lookup.getOrPut(gpa, entity);
        if (res.found_existing) return res.value_ptr.*;
        res.value_ptr.* = self.len;
        const offset = @sizeOf(Entity) * self.len;
        @memcpy(self.bytes[offset .. offset + @sizeOf(Entity)], std.mem.asBytes(&entity));
        self.len += 1;
        return res.value_ptr.*;
    }

    pub inline fn getEntity(self: *Self, index: usize) Entity {
        assert(self.len > index);
        const offset = @sizeOf(Entity) * index;
        const ent: *Entity = @ptrCast(@alignCast(self.bytes[offset .. offset + @sizeOf(Entity)]));
        return ent.*;
    }

    pub inline fn getSingleRawConst(self: *Self, index: usize, meta: *const ColMeta) []u8 {
        const comp_offset = meta.offset + meta.size * index;
        return self.bytes[comp_offset .. comp_offset + meta.size];
    }

    pub inline fn getSingleRaw(self: *Self, index: usize, meta: *const ColMeta) []u8 {
        const comp_offset = meta.offset + meta.size * index;
        return self.bytes[comp_offset .. comp_offset + meta.size];
    }

    pub inline fn getSingle(self: *Self, entity: Entity, comptime C: type) EcsError!*C {
        const index = self.entity_lookup.get(entity) orelse return EcsError.EntityNotFound;
        const flag = CompFlag.getFlag(C);
        const meta = self.getMeta(flag) orelse return EcsError.ComponentNotFound;
        return @ptrCast(@alignCast(self.getSingleRaw(index, meta)));
    }

    pub inline fn upateChanged(self: *Self, tick: u32, index: usize, comptime C: type) void {
        const flag = CompFlag.getFlag(C);
        const meta = self.getMeta(flag).?;
        const tick_offset = meta.offset + meta.size * self.capacity + @sizeOf(TickInfo) * index;
        @memcpy(self.bytes[tick_offset + 4 .. tick_offset + 8], std.mem.asBytes(&tick));
    }

    pub inline fn getSingleConst(self: *Self, entity: Entity, comptime C: type) EcsError!*const C {
        const index = self.entity_lookup.get(entity) orelse return EcsError.EntityNotFound;
        const flag = CompFlag.getFlag(C);
        const meta = self.getMeta(flag).?;
        return @ptrCast(@alignCast(self.getSingleRawConst(index, meta)));
    }

    pub inline fn getTickInfo(self: *Self, index: usize, meta: *const ColMeta) *const TickInfo {
        assert(self.len > index);
        const tick_offset = meta.offset + meta.size * self.capacity + @sizeOf(TickInfo) * index;
        return @ptrCast(@alignCast(self.bytes[tick_offset .. tick_offset + @sizeOf(TickInfo)]));
    }

    pub inline fn getMeta(self: *Self, flag: CompFlag) ?*const ColMeta {
        const index = self.column_lookup.get(flag) orelse return null;
        return &self.columns.items[index];
    }

    pub fn moveTo(
        self: *Self,
        gpa: std.mem.Allocator,
        entity: Entity,
        dst: *Self,
    ) !void {
        assert(@intFromPtr(self) != @intFromPtr(dst));
        assert(dst.capacity >= dst.len);

        // For adding components: dst should contain all of src's components
        // For removing components: src should contain all of dst's components
        const intersection = self.mask.intersectWith(dst.mask);
        assert(intersection.eql(self.mask) or intersection.eql(dst.mask));
        const src_index = self.entity_lookup.get(entity) orelse return EcsError.EntityNotFound;

        // ensure capacity of target arch
        if (dst.len >= dst.capacity) {
            try dst.setCapacity(gpa, dst.capacity + dst.chunk_size);
        }

        const dst_index = try dst.putEntity(gpa, entity);
        var skipped: u32 = 0;
        for (self.columns.items) |*meta| {
            const data = self.getSingleRawConst(src_index, meta);
            const info = self.getTickInfo(src_index, meta);

            const dst_meta = dst.getMeta(meta.flag) orelse {
                skipped += 1;
                continue;
            };

            dst.putRaw(info.changed, info.added, dst_index, dst_meta, data);
        }

        // generally there should only be one comp missing from the target
        assert(skipped < 2);

        try self.remove(gpa, entity);
    }

    inline fn swapRemoveComp(self: *Self, index: usize, meta: *ColMeta) void {
        assert(self.len > 0);

        const remove_offset = meta.offset + meta.size * index;
        const last_offset = meta.offset + meta.size * (self.len - 1);
        const tick_remove_offset = meta.offset + meta.size * self.capacity + @sizeOf(TickInfo) * index;
        const tick_last_offset = meta.offset + meta.size * self.capacity + @sizeOf(TickInfo) * (self.len - 1);

        @memcpy(
            self.bytes[remove_offset .. remove_offset + meta.size],
            self.bytes[last_offset .. last_offset + meta.size],
        );

        @memcpy(
            self.bytes[tick_remove_offset .. tick_remove_offset + @sizeOf(TickInfo)],
            self.bytes[tick_last_offset .. tick_last_offset + @sizeOf(TickInfo)],
        );
    }

    inline fn swapRemoveEntitiy(self: *Self, index: usize) void {
        assert(self.len > 0);

        const ent_size = @sizeOf(Entity);
        const remove_offset = ent_size * index;
        const last_offset = ent_size * (self.len - 1);

        @memcpy(
            self.bytes[remove_offset .. remove_offset + ent_size],
            self.bytes[last_offset .. last_offset + ent_size],
        );
    }

    pub fn cloneEmpty(self: *const Self, gpa: std.mem.Allocator) !Self {
        var clone = Self{};
        clone.bytes = undefined;
        clone.mask = self.mask;
        clone.alignment = self.alignment;
        clone.column_lookup = try self.column_lookup.clone(gpa);
        clone.columns = try self.columns.clone(gpa);
        clone.chunk_size = self.chunk_size;
        return clone;
    }

    /// Query struct by index with tick filter
    pub fn getFilteredIndex(
        self: *Self,
        tick: u32,
        index: usize,
        comptime Q: type,
        comptime filter: anytype,
    ) EcsError!Q {
        inline for (filter) |comp| {
            if (@hasDecl(comp, "_is_changed")) {
                const flag = CompFlag.getFlag(comp.inner);
                const meta = self.getMeta(flag).?;
                const info = self.getTickInfo(index, meta);
                if (info.changed < tick -| 1) return EcsError.EntityNotFound;
            }
            if (@hasDecl(comp, "_is_added")) {
                const flag = CompFlag.getFlag(comp.inner);
                const meta = self.getMeta(flag).?;
                const info = self.getTickInfo(index, meta);
                if (info.added < tick -| 1) return EcsError.EntityNotFound;
            }
        }

        return self.getQueryIndex(index, Q);
    }

    /// Query struct by index
    pub fn getQueryIndex(self: *Self, index: usize, comptime Q: type) EcsError!Q {
        var row: Q = undefined;
        const info = @typeInfo(Q).@"struct";

        inline for (info.fields) |field| {
            // entity
            if (field.type == Entity) {
                @field(row, field.name) = self.getEntity(index);
                continue;
            }
            // skip tags
            if (@sizeOf(field.type) == 0) {
                @field(row, field.name) = .{};
                continue;
            }

            const field_ptr = switch (@typeInfo(field.type)) {
                .pointer => @typeInfo(field.type).pointer,
                .optional => |opt| @typeInfo(opt.child).pointer,
                else => @compileError("Type not allowed: " ++ field.name),
            };

            const flag = CompFlag.getFlag(field_ptr.child);
            if (self.getMeta(flag)) |meta| {
                if (field_ptr.is_const) {
                    const raw_bytes = self.getSingleRawConst(index, meta);
                    @field(row, field.name) = @ptrCast(@alignCast(raw_bytes));
                } else {
                    const raw_bytes = self.getSingleRaw(index, meta);
                    @field(row, field.name) = @ptrCast(@alignCast(raw_bytes));
                }
            } else {
                if (@typeInfo(field.type) == .optional) {
                    @field(row, field.name) = null;
                } else {
                    return EcsError.ComponentNotFound;
                }
            }
        }

        return row;
    }

    /// calc table offsets per comp
    inline fn calcTableOffsets(self: *Self) void {
        assert(self.len == 0);
        // Ensure entity section is aligned to the maximum component alignment
        var offset = std.mem.alignForward(usize, @sizeOf(Entity) * self.capacity, self.alignment);
        for (self.columns.items) |*meta| {
            const typeId = meta.flag.getId();
            offset = std.mem.alignForward(usize, offset, typeId.alignment);
            meta.offset = offset;
            offset += meta.size * self.capacity + @sizeOf(TickInfo) * self.capacity;
        }
    }

    /// realloc memory to new capacity
    /// new capaicty > current or crash
    pub fn setCapacity(self: *Self, gpa: std.mem.Allocator, new_capacity: usize) !void {
        assert(new_capacity >= self.len);
        // new size
        var size = std.mem.alignForward(usize, @sizeOf(Entity) * new_capacity, self.alignment);
        var offset = size;
        for (self.columns.items) |meta| {
            const typeId = meta.flag.getId();
            offset = std.mem.alignForward(usize, offset, typeId.alignment);
            offset += meta.size * new_capacity + @sizeOf(TickInfo) * new_capacity;
        }
        size = offset;

        const new_bytes = (gpa.rawAlloc(
            size,
            std.mem.Alignment.fromByteUnits(self.alignment),
            @returnAddress(),
        ) orelse return error.OutOfMemory)[0..size];

        if (self.capacity == 0) {
            self.bytes = new_bytes;
            self.capacity = new_capacity;
            self.calcTableOffsets();
            return;
        }

        // copy entities
        const entity_size = @sizeOf(Entity) * self.len;
        @memcpy(new_bytes[0..entity_size], self.bytes[0..entity_size]);

        // offset to comp table
        var new_offset = std.mem.alignForward(usize, @sizeOf(Entity) * new_capacity, self.alignment);

        for (self.columns.items) |*meta| {
            // Align new offset
            const typeId = meta.flag.getId();
            new_offset = std.mem.alignForward(usize, new_offset, typeId.alignment);

            // Copy component data
            const old_comp_offset = meta.offset;
            const copy_size = meta.size * self.len;
            @memcpy(
                new_bytes[new_offset .. new_offset + copy_size],
                self.bytes[old_comp_offset .. old_comp_offset + copy_size],
            );

            meta.offset = new_offset;

            // Move to tick section (both old and new)
            const old_tick_offset = old_comp_offset + meta.size * self.capacity;
            new_offset += meta.size * new_capacity;

            const tick_size = @sizeOf(TickInfo) * self.len;
            @memcpy(
                new_bytes[new_offset .. new_offset + tick_size],
                self.bytes[old_tick_offset .. old_tick_offset + tick_size],
            );

            new_offset += @sizeOf(TickInfo) * new_capacity;
        }

        gpa.free(self.bytes);
        self.bytes = new_bytes;
        self.capacity = new_capacity;
    }
};

// *************************************************
// Arch Registry
// *************************************************
pub const ArchRegistry = struct {
    // _ = max_components;
    const Self = @This();
    const CHUNK_SIZE: usize = 64;
    // --------------------------- TODO: group these
    // const EntityMeta = struct { arch_id: usize, mask: Co };
    /// entity -> mask
    mask_lookup: std.AutoHashMapUnmanaged(Entity, CompFlag.Set) = .{},
    /// entity -> arch id
    entity_lookup: std.AutoHashMapUnmanaged(Entity, usize) = .{},
    /// group mask -> arch id
    archtypes_lookup: std.AutoHashMapUnmanaged(CompFlag.Set, usize) = .{},
    archtypes: std.ArrayList(ArchType) = .{},

    pub fn getOrPutMask(self: *Self, gpa: std.mem.Allocator, entity: Entity) !*CompFlag.Set {
        const res = try self.mask_lookup.getOrPut(gpa, entity);
        if (!res.found_existing) {
            res.value_ptr.* = CompFlag.Set.initEmpty();
        }
        return res.value_ptr;
    }

    pub fn add(self: *Self, allocator: std.mem.Allocator, tick: u32, entity: Entity, comp: anytype) !void {
        const CompType = @TypeOf(comp);
        const flag = CompFlag.getFlag(CompType);

        var mask = try self.getOrPutMask(allocator, entity);
        const current_arch_id = self.archtypes_lookup.get(mask.*);

        if (mask.contains(flag)) {
            const arch = &self.archtypes.items[current_arch_id.?];
            try arch.put(allocator, tick, entity, .{comp});
            return;
        }

        mask.insert(flag);

        // add to new
        const new_arch_id = try self.archtypes_lookup.getOrPut(allocator, mask.*);
        if (!new_arch_id.found_existing) {
            // create
            if (current_arch_id) |current_id| {
                const cloned = try self.archtypes.items[current_id].cloneEmpty(allocator);
                try self.archtypes.append(allocator, cloned);
                new_arch_id.value_ptr.* = self.archtypes.items.len - 1;
            } else {
                try self.archtypes.append(allocator, .{ .chunk_size = CHUNK_SIZE });
                new_arch_id.value_ptr.* = self.archtypes.items.len - 1;
            }

            // add new comp
            try self.archtypes.items[new_arch_id.value_ptr.*].addComp(allocator, flag);
            try self.archtypes.items[new_arch_id.value_ptr.*].setCapacity(allocator, CHUNK_SIZE);
        }

        if (current_arch_id) |current_id| {
            try self.archtypes.items[current_id].moveTo(
                allocator,
                entity,
                &self.archtypes.items[new_arch_id.value_ptr.*],
            );
            try self.archtypes.items[new_arch_id.value_ptr.*].putSingle(allocator, tick, entity, comp);
        } else {
            try self.archtypes.items[new_arch_id.value_ptr.*].put(allocator, tick, entity, .{comp});
        }

        try self.entity_lookup.put(allocator, entity, new_arch_id.value_ptr.*);
    }

    pub fn addBundle(self: *Self, allocator: std.mem.Allocator, tick: u32, entity: Entity, bundle: anytype) !void {
        var mask = try self.getOrPutMask(allocator, entity);

        const current_arch_id = self.archtypes_lookup.get(mask.*);
        const is_new_entity = current_arch_id == null;

        const old_mask = mask.*;
        inline for (bundle) |comp| {
            const CompType = @TypeOf(comp);
            if (isTuple(CompType)) continue;

            const flag = CompFlag.getFlag(CompType);
            mask.insert(flag);
        }

        const same_arch = mask.eql(old_mask);

        const next_arch_id = try self.archtypes_lookup.getOrPut(allocator, mask.*);
        if (!next_arch_id.found_existing and !same_arch) {
            if (is_new_entity) {
                try self.archtypes.append(allocator, .{});
            } else {
                const cloned = try self.archtypes.items[current_arch_id.?].cloneEmpty(allocator);
                try self.archtypes.append(allocator, cloned);
            }

            next_arch_id.value_ptr.* = self.archtypes.items.len - 1;

            inline for (bundle) |comp| {
                const CompType = @TypeOf(comp);
                if (isTuple(CompType)) continue;

                const flag = CompFlag.getFlag(CompType);
                try self.archtypes.items[next_arch_id.value_ptr.*].addComp(allocator, flag);
            }

            try self.archtypes.items[next_arch_id.value_ptr.*].setCapacity(allocator, CHUNK_SIZE);
        }

        if (!is_new_entity and !same_arch) {
            try self.archtypes.items[current_arch_id.?].moveTo(
                allocator,
                entity,
                &self.archtypes.items[next_arch_id.value_ptr.*],
            );
        }

        try self.archtypes.items[next_arch_id.value_ptr.*].put(allocator, tick, entity, bundle);
        _ = try self.entity_lookup.put(allocator, entity, next_arch_id.value_ptr.*);
    }

    pub fn getSingle(self: *Self, entity: Entity, comptime C: type) ?*C {
        const arch_id = self.entity_lookup.get(entity) orelse return null;
        return self.archtypes.items[arch_id].getSingle(entity, C) catch null;
    }

    pub fn getSingleOpaque(self: *Self, entity: Entity, flag: CompFlag) ?*anyopaque {
        const arch_id = self.entity_lookup.get(entity) orelse return null;
        const meta = self.archtypes.items[arch_id].getMeta(flag) orelse return null;
        const index = self.archtypes.items[arch_id].entity_lookup.get(entity) orelse return null;
        return self.archtypes.items[arch_id].getSingleRaw(index, meta).ptr;
    }

    pub fn remove(self: *Self, allocator: std.mem.Allocator, entity: Entity, comptime C: type) !void {
        const flag = CompFlag.getFlag(C);
        var mask = try self.getOrPutMask(allocator, entity);
        const current_arch_id = self.entity_lookup.get(entity) orelse return EcsError.EntityNotFound;

        // TODO: failsafe required?
        if (!mask.contains(flag)) return;
        // assert(mask.contains(flag));

        mask.remove(flag);
        const new_arch_id = try self.archtypes_lookup.getOrPut(allocator, mask.*);

        if (!new_arch_id.found_existing) {
            var new_arch = try self.archtypes.items[current_arch_id].cloneEmpty(allocator);
            new_arch.removeComp(flag);
            try new_arch.setCapacity(allocator, CHUNK_SIZE);
            try self.archtypes.append(allocator, new_arch);
            new_arch_id.value_ptr.* = self.archtypes.items.len - 1;
        }

        // TODO: deinit removed comp if it owns memory
        // like `Children`

        const new_arch = &self.archtypes.items[new_arch_id.value_ptr.*];
        try self.archtypes.items[current_arch_id].moveTo(allocator, entity, new_arch);
        _ = try self.entity_lookup.put(allocator, entity, new_arch_id.value_ptr.*);
    }

    /// TODO: deinit allocating components
    pub fn despawn(self: *Self, allocator: std.mem.Allocator, entity: Entity) !void {
        const arch_id = self.entity_lookup.get(entity) orelse return;
        try self.archtypes.items[arch_id].remove(allocator, entity);
        _ = self.entity_lookup.remove(entity);
    }
};

pub const ArchIter = struct {
    const Self = @This();
    const empty = CompFlag.Set.initEmpty();
    reg: []ArchType,
    include: CompFlag.Set,
    exclude: CompFlag.Set,
    index: usize = 0,

    pub fn next(self: *Self) ?*ArchType {
        while (self.index < self.reg.len) {
            const mask = self.reg[self.index].mask;
            const next_arch = &self.reg[self.index];
            self.index += 1;

            if (self.include.intersectWith(mask).eql(self.include) and self.exclude.intersectWith(mask).eql(empty) and next_arch.len > 0) {
                return next_arch;
            }
        }
        return null;
    }

    pub fn reset(self: *@This()) void {
        self.index = 0;
    }
};

pub const EntityIter = struct {
    const Self = @This();
    arch_iter: ArchIter,
    current: ?*ArchType = null,
    offset: usize = 0,

    pub fn next(self: *Self) ?Entity {
        while (true) {
            if (self.current) |current_arch| {
                if (self.offset >= current_arch.len) {
                    self.current = null;
                    self.offset = 0;
                    continue;
                }

                const next_item = current_arch.getEntity(self.offset);
                self.offset += 1;
                return next_item;
            }

            self.current = self.arch_iter.next() orelse return null;
            self.offset = 0;
        }
    }
};

//---------------------------------------
pub fn Qiter(max_components: comptime_int, comptime Q: type, comptime filter: anytype) type {
    _ = max_components; // autofix
    return struct {
        const Self = @This();
        arch_iter: ArchIter,
        current: ?*ArchType = null,
        offset: usize = 0,
        world_tick: u32,

        pub fn next(self: *Self) ?Q {
            while (true) {
                if (self.current) |current_arch| {
                    if (self.offset >= current_arch.len) {
                        self.current = null;
                        self.offset = 0;
                        continue;
                    }

                    const next_item = current_arch.getFilteredIndex(self.world_tick, self.offset, Q, filter) catch {
                        self.offset += 1;
                        continue;
                    };

                    self.offset += 1;
                    return next_item;
                }

                self.current = self.arch_iter.next() orelse return null;
                self.offset = 0;
            }
        }

        /// mark a component of the current iteration as changed.
        /// should only be called inside a iteration loop.
        pub fn changed(self: *Self, comptime C: type) void {
            assert(self.offset > 0);
            assert(self.current != null);
            const index = self.offset - 1; // current iteration
            self.current.?.upateChanged(self.world_tick, index, C);
        }
    };
}

const QueryMask = struct {
    read_set: CompFlag.Set = .{},
    write_set: CompFlag.Set = .{},
    include_set: CompFlag.Set = .{},
    exclude_set: CompFlag.Set = .{},
};

fn extractQuerySets(comptime query: anytype, comptime filter: anytype) QueryMask {
    var set: QueryMask = .{};

    inline for (query) |comp| {
        const info = @typeInfo(comp);
        switch (info) {
            .optional => |opt| {
                if (@hasDecl(opt.child, "_is_mut")) {
                    const comp_id = CompFlag.getFlag(opt.child.inner);
                    set.write_set.insert(comp_id);
                    set.read_set.insert(comp_id);
                } else {
                    const comp_id = CompFlag.getFlag(opt.child);
                    set.read_set.insert(comp_id);
                }
            },
            .@"struct" => |str| {
                if (str.is_tuple) @compileLog("query tuple not allowed");
                if (@hasDecl(comp, "_is_mut")) {
                    const comp_id = CompFlag.getFlag(comp.inner);
                    set.read_set.insert(comp_id);
                    set.write_set.insert(comp_id);
                    set.include_set.insert(comp_id);
                    continue;
                } else {
                    const comp_id = CompFlag.getFlag(comp);
                    set.include_set.insert(comp_id);
                    set.read_set.insert(comp_id);
                }
            },
            .@"enum" => {
                const comp_id = CompFlag.getFlag(comp);
                set.include_set.insert(comp_id);
                set.read_set.insert(comp_id);
            },
            else => @compileError("not allowed"),
        }
    }

    inline for (filter) |comp| {
        if (@hasDecl(comp, "_is_with") or @hasDecl(comp, "_is_changed") or @hasDecl(comp, "_is_added")) {
            const flag = CompFlag.getFlag(comp.inner);
            set.include_set.insert(flag);
            set.read_set.insert(flag);
        }
        if (@hasDecl(comp, "_is_without")) {
            const flag = CompFlag.getFlag(comp.inner);
            set.exclude_set.insert(flag);
        }
    }

    return set;
}

fn IsRead(comptime T: type, comptime query: anytype) bool {
    var found = false;
    inline for (query) |comp| {
        switch (@typeInfo(comp)) {
            .optional => |opt| {
                if (T == opt.child) found = true;
            },
            else => {
                if (T == comp) found = true;
            },
        }
    }
    return found;
}

fn IsWrite(comptime T: type, comptime query: anytype) bool {
    var found = false;
    inline for (query) |comp| {
        switch (@typeInfo(comp)) {
            .optional => |opt| {
                if (@hasDecl(opt.child, "_is_mut")) {
                    if (T == opt.child.inner) found = true;
                }
            },
            else => {
                if (@hasDecl(comp, "_is_mut")) {
                    if (T == comp.inner) found = true;
                }
            },
        }
    }
    return found;
}

pub fn IQueryFiltered(comptime desc: AppDesc, comptime query: anytype, comptime filter: anytype) type {
    return struct {
        const Self = @This();
        exclude: CompFlag.Set,
        include: CompFlag.Set,
        reg: *ArchRegistry,
        world_tick: u32,

        /// comptime query validation
        inline fn validate_query(comptime Q: type) void {
            for (@typeInfo(Q).@"struct".fields) |field| {
                const info = @typeInfo(field.type);
                if (field.type == Entity) continue;

                const field_ptr = switch (info) {
                    .optional => |opt| switch (@typeInfo(opt.child)) {
                        .pointer => |p| p,
                        else => @compileError("non pointer type is not allowed in query " ++ field.name),
                    },
                    .pointer => |p| p,
                    else => @compileError("non pointer type is not allowed in query " ++ field.name),
                };

                if (field_ptr.is_const) {
                    if (!IsRead(field_ptr.child, query)) {
                        @compileError("Component not in query! field: `" ++ field.name ++ "` type:" ++ @typeName(field_ptr.child));
                    }
                } else {
                    if (!IsWrite(field_ptr.child, query)) {
                        @compileError("Component not mutable in query! field: `" ++ field.name ++ "` type:" ++ @typeName(field_ptr.child));
                    }
                }
            }
        }

        pub fn addAccess(access: *Access) void {
            const set = extractQuerySets(query, filter);
            access.comp_read_write = access.comp_read_write.unionWith(set.read_set);
            access.comp_write = access.comp_write.unionWith(set.write_set);
        }

        /// query iterate
        pub fn iterQ(self: *const Self, comptime Q: type) Qiter(desc.max_components, Q, filter) {
            comptime validate_query(Q);
            return Qiter(desc.max_components, Q, filter){
                .world_tick = self.world_tick,
                .arch_iter = ArchIter{
                    .include = self.include,
                    .exclude = self.exclude,
                    .reg = self.reg.archtypes.items,
                },
            };
        }

        pub fn iterEntity(self: *const Self) EntityIter {
            return EntityIter{
                .arch_iter = ArchIter{
                    .include = self.include,
                    .exclude = self.exclude,
                    .reg = self.reg.archtypes.items,
                },
            };
        }

        pub fn count(self: *const Self) usize {
            var iter = ArchIter{
                .include = self.include,
                .exclude = self.exclude,
                .reg = self.reg.archtypes.items,
            };

            var c: usize = 0;
            while (iter.next()) |arch| {
                c += arch.len;
            }

            return c;
        }

        /// get query entry single
        pub fn getQ(self: *const Self, entity: Entity, comptime Q: type) EcsError!Q {
            comptime validate_query(Q);
            const arch_id = self.reg.entity_lookup.get(entity) orelse return EcsError.EntityNotFound;
            const arch = &self.reg.archtypes.items[arch_id];
            const index = arch.entity_lookup.get(entity).?; // orelse return EcsError.EntityNotFound;
            return arch.getFilteredIndex(self.world_tick, index, Q, filter);
        }

        pub fn fromWorld(world: *App(desc)) EcsError!Self {
            const set = extractQuerySets(query, filter);
            return Self{
                .exclude = set.exclude_set,
                .include = set.include_set,
                .reg = &world.archtypes,
                .world_tick = world.world_tick,
            };
        }

        pub fn empty(world: *App(desc)) Self {
            return Self{
                .reg = &world.archtypes,
                .exclude = CompFlag.Set.initEmpty(),
                .include = CompFlag.Set.initEmpty(),
                .world_tick = world.world_tick,
            };
        }

        pub fn setWorldTick(self: *Self, tick: u32) void {
            self.world_tick = tick;
        }
    };
}

pub const Config = struct {
    max_threads: u8 = 16,
};

/// tiny and simple thread pool, that does not leak memory.
/// TODO: add threading stats avg per frame
pub fn Executor(comptime cfg: Config) type {
    return struct {
        const Self = @This();
        const Atomic = std.atomic.Value;
        const Thread = std.Thread;
        const RunQueue = std.SinglyLinkedList;
        const Runnable = struct { runFn: RunProto, node: std.SinglyLinkedList.Node = .{} };
        const RunProto = *const fn (*Runnable) void;

        // ------------------------------------------------------------
        // TODO: threading stats!
        //const ExThread = struct{
        //  thread: Thread,
        //  avg_load: f32, // time spent executing on avg
        //}

        threads: [cfg.max_threads]Thread = [_]Thread{undefined} ** cfg.max_threads,
        running: Atomic(bool) = .{ .raw = false },
        queue: RunQueue = .{},
        gpa: std.mem.Allocator,
        mutex: std.Thread.Mutex = .{},
        queued: Atomic(usize) = .{ .raw = 0 },
        active_threads: Atomic(usize) = .{ .raw = 0 },
        cond: std.Thread.Condition = .{},

        // ------------------------------------------------------------

        pub fn init(gpa: std.mem.Allocator) Self {
            return .{ .gpa = gpa };
        }

        pub fn deinit(self: *Self) void {
            self.join();
        }

        pub fn start(self: *Self) !void {
            self.running.store(true, .monotonic);
            if (builtin.single_threaded) return;

            for (self.threads[0..cfg.max_threads]) |*slot| {
                if (Thread.spawn(.{}, worker, .{self})) |thread| {
                    slot.* = thread;
                    _ = self.active_threads.fetchAdd(1, .monotonic);
                } else |_| {}
            }
        }

        pub fn shutdown(self: *Self) void {
            self.running.store(false, .acq_rel);
        }

        pub fn isRunning(self: *Self) bool {
            return self.running.load(.monotonic);
        }

        fn join(self: *Self) void {
            for (self.threads) |thread| thread.join();
        }

        fn worker(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (self.isRunning()) {
                while (self.queue.popFirst()) |run_node| {
                    self.mutex.unlock();
                    defer self.mutex.lock();

                    const runable: *Runnable = @fieldParentPtr("node", run_node);
                    runable.runFn(runable);
                }

                self.cond.wait(&self.mutex);
            }
            _ = self.active_threads.fetchSub(1, .acq_rel);
        }

        /// add job to current batch
        pub fn run(
            self: *Self,
            group: *Thread.WaitGroup,
            comptime func: anytype,
            args: anytype,
        ) !void {
            group.start();
            const Args = @TypeOf(args);
            const Closure = struct {
                args: Args,
                executor: *Self,
                runnable: Runnable = .{ .runFn = runFn },
                work_group: *Thread.WaitGroup,

                fn runFn(runnable: *Runnable) void {
                    const closure: *@This() = @alignCast(@fieldParentPtr("runnable", runnable));
                    @call(.auto, func, closure.args);

                    // cleanup
                    const mutex = &closure.executor.mutex;
                    const work_group = closure.work_group;

                    mutex.lock();
                    closure.executor.gpa.destroy(closure);
                    mutex.unlock();
                    work_group.finish();
                }
            };

            if (builtin.single_threaded) {
                @call(.auto, func, args);
                group.finish();
                return;
            }

            {
                self.mutex.lock();
                const closure = self.gpa.create(Closure) catch {
                    self.mutex.unlock();
                    @call(.auto, func, args);
                    group.finish();
                    return;
                };
                closure.* = .{
                    .args = args,
                    .executor = self,
                    .work_group = group,
                };
                self.queue.prepend(&closure.runnable.node);
                self.mutex.unlock();
            }

            // Wake up a waiting worker
            self.cond.signal();
        }
    };
}

pub fn HookRegistry(desc: AppDesc) type {
    return struct {
        const Self = @This();
        const World = App(desc);
        pub const HookFn = *const fn (*anyopaque, Entity, *World) EcsError!void;
        pub const Hook = struct {
            run: HookFn,
        };
        has_add_hook: CompFlag.Set = .{},
        has_remove_hook: CompFlag.Set = .{},
        has_despawn_hook: CompFlag.Set = .{},
        // --------------------
        add_hooks: std.AutoHashMapUnmanaged(CompFlag, std.ArrayList(Hook)) = .{},
        remove_hooks: std.AutoHashMapUnmanaged(CompFlag, std.ArrayList(Hook)) = .{},
        despawn_hooks: std.AutoHashMapUnmanaged(CompFlag, std.ArrayList(Hook)) = .{},

        pub fn runAddedHook(self: *Self, flag: CompFlag, comp: *anyopaque, entity: Entity, world: *World) !void {
            const hooks = self.add_hooks.get(flag) orelse return;
            for (hooks.items) |hook| try hook.run(comp, entity, world);
        }

        pub fn runRemoveHook(self: *Self, flag: CompFlag, comp: *anyopaque, entity: Entity, world: *World) !void {
            const hooks = self.remove_hooks.get(flag) orelse return;
            for (hooks.items) |hook| try hook.run(comp, entity, world);
        }

        pub fn runDespawnHook(self: *Self, flag: CompFlag, comp: *anyopaque, entity: Entity, world: *World) !void {
            const hooks = self.despawn_hooks.get(flag) orelse return;
            for (hooks.items) |hook| try hook.run(comp, entity, world);
        }

        pub fn OnRemoveComp(
            self: *Self,
            gpa: std.mem.Allocator,
            comptime T: type,
            comptime hook_fn: *const fn (*T, Entity, *World) EcsError!void,
        ) EcsError!void {
            const hook = Hook{ .run = (struct {
                fn run(ptr: *anyopaque, entity: Entity, world: *World) EcsError!void {
                    const comp: *T = @ptrCast(@alignCast(ptr));
                    try hook_fn(comp, entity, world);
                }
            }).run };

            const flag = CompFlag.getFlag(T);
            self.has_remove_hook.insert(flag);

            const res = try self.remove_hooks.getOrPut(gpa, flag);
            if (!res.found_existing) res.value_ptr.* = .{};
            try res.value_ptr.append(gpa, hook);
        }

        pub fn OnDespawnComp(
            self: *Self,
            gpa: std.mem.Allocator,
            comptime T: type,
            comptime hook_fn: *const fn (*T, Entity, *World) EcsError!void,
        ) EcsError!void {
            const hook = Hook{ .run = (struct {
                fn run(ptr: *anyopaque, entity: Entity, world: *World) EcsError!void {
                    const comp: *T = @ptrCast(@alignCast(ptr));
                    try hook_fn(comp, entity, world);
                }
            }).run };

            const flag = CompFlag.getFlag(T);
            self.has_despawn_hook.insert(flag);

            const res = try self.despawn_hooks.getOrPut(gpa, flag);
            if (!res.found_existing) res.value_ptr.* = .{};
            try res.value_ptr.append(gpa, hook);
        }

        pub fn OnAddComp(
            self: *Self,
            gpa: std.mem.Allocator,
            comptime T: type,
            comptime hook_fn: *const fn (*T, Entity, *World) EcsError!void,
        ) EcsError!void {
            const hook = Hook{ .run = (struct {
                fn run(ptr: *anyopaque, entity: Entity, world: *World) EcsError!void {
                    const comp: *T = @ptrCast(@alignCast(ptr));
                    try hook_fn(comp, entity, world);
                }
            }).run };

            const flag = CompFlag.getFlag(T);
            self.has_add_hook.insert(flag);

            const res = try self.add_hooks.getOrPut(gpa, flag);
            if (!res.found_existing) res.value_ptr.* = .{};
            try res.value_ptr.append(gpa, hook);
        }
    };
}
