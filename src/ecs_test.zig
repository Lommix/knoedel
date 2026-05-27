const std = @import("std");
const e = @import("ecs.zig");

const expect = std.testing.expect;
const Entity = e.Entity;
const ArchType = e.ArchType;
const App = e.App;
const EcsError = e.EcsError;

fn testIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// -------------------------------------
// tests
test "ecs" {
    const Foo = struct { n: i32 };
    const Bar = struct { n: i32 };
    const Baz = struct { n: i32 };

    const app = App(.{});
    var ecs = try app.init(std.testing.allocator, testIo());
    defer ecs.deinit();

    const alloc = ecs.memtator.world();

    const ent1 = ecs.nextEntityId();
    const ent2 = ecs.nextEntityId();

    try ecs.components.add(alloc, 0, ent1, Foo{ .n = 1 });
    try ecs.components.add(alloc, 0, ent1, Baz{ .n = 11 });
    try ecs.components.add(alloc, 0, ent1, Bar{ .n = 22 });
    try ecs.components.add(alloc, 0, ent2, Foo{ .n = 2 });
    try ecs.components.add(alloc, 0, ent2, Bar{ .n = 22 });

    try ecs.components.remove(alloc, ent2, Bar);
    try ecs.components.remove(alloc, ent2, Foo);

    const q1 = try app.Query(struct { entity: Entity, foo: *const Foo }).fromWorld(ecs);
    var viewIter = q1.iter();
    var count: u32 = 0;

    while (viewIter.next()) |en| {
        try expect(en.foo.n == 1);
        count += 1;
    }

    try expect(count == 1);

    const cmd = ecs.getCommands();
    try cmd.despawn(ent2);

    ecs.update();

    const q2 = try app.Query(struct { b: *const Baz, f: *const Foo }).fromWorld(ecs);
    var bazIter = q2.iter();
    count = 0;
    while (bazIter.next()) |en| {
        try expect(en.b.n == 11);
        count += 1;
    }

    try expect(count == 1);
}

test "commands" {
    const Foo = struct { n: i32 };

    const app = App(.{});
    var ecs = try app.init(std.testing.allocator, testIo());
    defer ecs.deinit();

    const cmd = ecs.getCommands();
    const entity = try cmd.spawn(.{Foo{ .n = 69 }});

    ecs.update();
    try expect(ecs.entities.count == 1);
    try expect(entity.id() == 1);

    const q = try App(.{}).Query(struct { entity: Entity, foo: *const Foo }).fromWorld(ecs);
    var view = q.iter();

    var count: u32 = 0;
    while (view.next()) |en| {
        try expect(en.foo.n == 69);
        count += 1;
    }

    try expect(count == 1);
}

test "system" {
    const Foo = struct { i: u32 };
    const Too = struct { i: u32 };
    const Bar = struct { i: u32 };
    const Liz = struct { i: u32 = 0 };

    const a = App(.{});
    var world = try a.init(std.testing.allocator, testIo());
    defer world.deinit();

    // -------------
    // setup
    const cmd = world.getCommands();

    _ = try cmd.spawn(.{
        Too{ .i = 32 },
        Foo{ .i = 69 },
    });

    try world.addResource(Bar{ .i = 420 });
    world.update();
    // -------------

    const sys = (struct {
        fn sys_test(
            c: a.Commands,
            query: a.Query(struct { foo: *const Foo }),
            bar: a.ResMut(Bar),
            liz: e.Local(Liz),
        ) EcsError!void {
            _ = try c.spawn(.{Foo{ .i = 21 }});
            try expect(liz.inner.i == 0);

            var it = query.iter();
            const en = it.next().?;
            try expect(en.foo.i == 69);
            try expect(bar.inner.i == 420);
        }
    }).sys_test;

    const sys2 = (struct {
        fn sys_test(
            c: a.Commands,
            query: a.Query(struct { foo: *const Foo, too: *Too }),
            bar: a.Res(Bar),
            liz: e.Local(Liz),
        ) EcsError!void {
            _ = try c.spawn(.{Foo{ .i = 22 }});

            var it = query.iter();

            const en = it.next().?;

            // var count: u32 = 0;
            // for (try query.iterSetMut(Too)) |_| {
            //     count += 1;
            // }

            liz.inner.i += 1;
            // std.debug.print("{d}>", .{liz.inner.i});

            // try expect(count == 1);
            try expect(en.foo.i == 69);
            try expect(en.too.i == 32);
            try expect(bar.inner.i == 420);
        }
    }).sys_test;

    const Schedule = enum {
        update,
    };

    try world.addSystem(Schedule.update, &sys);
    try world.addSystem(Schedule.update, &sys2);

    for (0..10) |_| {
        try world.systems.runPar(Schedule.update, world);
        world.update();
    }

    // try expect(world.entityCount() == 21);
}

test "local" {
    const app = App(.{});
    var world = try app.init(std.testing.allocator, testIo());
    defer world.deinit();
}

test "scheduler ignores skipped active dependencies" {
    const Counter = struct { calls: u32 = 0 };
    const Ran = struct { count: u32 = 0 };

    const app = App(.{});
    var world = try app.init(std.testing.allocator, testIo());
    defer world.deinit();

    try world.addResource(Counter{});
    try world.addResource(Ran{});

    const Schedule = enum { update };

    const condition = (struct {
        fn run(w: *app, _: *e.ResourceRegistry(u6)) EcsError!bool {
            const counter = try w.resource(Counter);
            counter.calls += 1;
            return counter.calls == 2;
        }
    }).run;

    const first = (struct {
        fn run() EcsError!void {}
    }).run;

    const second = (struct {
        fn run(ran: app.ResMut(Ran)) EcsError!void {
            ran.inner.count += 1;
        }
    }).run;

    try world.addSystemEx(Schedule.update, e.Chain(.{ &first, &second }), &condition);
    try world.systems.run(Schedule.update, world);

    try expect((try world.resource(Counter)).calls == 2);
    try expect((try world.resource(Ran)).count == 1);
}

test "test_resource" {
    const TestRes = struct {
        a: u32 = 0,
    };

    const MissingRes = struct {};

    const res = TestRes{ .a = 69 };

    const app = App(.{});
    var world = try app.init(std.testing.allocator, testIo());
    defer world.deinit();

    try world.addResource(res);

    const r = try world.resource(TestRes);
    try std.testing.expect(r.a == 69);
    try std.testing.expect(world.resource(MissingRes) == EcsError.ResourceNotFound);
}

test "children_despawn" {
    const Foo = struct { a: u32 = 0 };
    const Bar = struct { b: u32 = 1 };
    const Biz = struct { c: u32 = 2 };

    const app = App(.{});
    var world = try app.init(std.testing.allocator, testIo());
    defer world.deinit();
    const gpa = world.memtator.world();

    const cmd = world.getCommands();

    var list: std.ArrayList(Entity) = .empty;
    defer list.deinit(gpa);

    for (0..500) |_| {
        const ent = try cmd.spawn(.{
            Bar{},
            Biz{},
            .{
                Foo{},
                Bar{},
                Biz{},
            },
        });

        try list.append(gpa, ent);
    }

    world.update();

    for (list.items) |ent| {
        try cmd.despawn(ent);
    }

    world.update();

    const q = try app.Query(struct { foo: *const Foo }).fromWorld(world);
    var it = q.iter();
    while (it.next()) |en| {
        std.debug.print("THIS SHOULD NOT HAPPEN {any}\n", .{en});
    }

    try expect(world.entityCount() == 0);
}

test "claimEntityId despawns existing slot generation" {
    const Foo = struct { n: i32 };

    const app = App(.{});
    var world = try app.init(std.testing.allocator, testIo());
    defer world.deinit();

    const cmd = world.getCommands();
    const original = try cmd.spawn(.{Foo{ .n = 1 }});
    world.update();

    var claimed = original;
    claimed.incGen();
    try world.claimEntityId(claimed);
    try cmd.spawnWithEntity(claimed, .{Foo{ .n = 2 }});
    world.update();

    const q = try app.Query(struct { entity: Entity, foo: *const Foo }).fromWorld(world);
    var it = q.iter();
    const row = it.next().?;
    try expect(row.entity == claimed);
    try expect(row.foo.n == 2);
    try expect(it.next() == null);
    try expect(world.entityCount() == 1);
}

test "despawn tolerates stale child ids" {
    const app = App(.{});
    var world = try app.init(std.testing.allocator, testIo());
    defer world.deinit();

    const parent = world.nextEntityId();
    var children = e.Children{};
    try children.items.append(world.memtator.world(), Entity.new(999));
    try world.components.add(world.memtator.world(), 0, parent, children);

    const cmd = world.getCommands();
    try cmd.despawn(parent);
    world.update();

    try expect(world.entityCount() == 0);
}

test "temporary queries allocate match state from frame arena" {
    const Foo = struct { n: i32 };

    const app = App(.{});
    var world = try app.init(std.testing.allocator, testIo());
    defer world.deinit();

    const cmd = world.getCommands();
    _ = try cmd.spawn(.{Foo{ .n = 1 }});
    world.update();

    const before = world.memtator.stats().world_mem;
    for (0..64) |_| {
        const q = try app.Query(struct { foo: *const Foo }).fromWorld(world);
        try expect(q.count() == 1);
    }
    const after = world.memtator.stats().world_mem;

    try expect(after == before);
}

test "query filters support Or and Or3 shorthand" {
    const Foo = struct { n: i32 };
    const Bar = struct { n: i32 };
    const Baz = struct { n: i32 };

    const app = App(.{});
    var world = try app.init(std.testing.allocator, testIo());
    defer world.deinit();

    const foo_ent = world.nextEntityId();
    const bar_ent = world.nextEntityId();
    const baz_ent = world.nextEntityId();
    try world.components.add(world.memtator.world(), world.world_tick, foo_ent, Foo{ .n = 1 });
    try world.components.add(world.memtator.world(), world.world_tick, bar_ent, Bar{ .n = 2 });
    try world.components.add(world.memtator.world(), world.world_tick, baz_ent, Baz{ .n = 3 });

    const q_or = try app.QueryF(
        struct { entity: Entity },
        .Or(.With(Foo), .With(Bar)),
    ).fromWorld(world);
    try expect(q_or.count() == 2);

    const q_or3 = try app.QueryF(
        struct { entity: Entity },
        .Or3(.With(Foo), .With(Bar), .With(Baz)),
    ).fromWorld(world);
    try expect(q_or3.count() == 3);

    const q_or_ticks = try app.QueryF(
        struct { entity: Entity },
        .Or(.Added(Foo), .Changed(Bar)),
    ).fromWorld(world);
    var or_ticks_it = q_or_ticks.iter();
    var or_ticks_count: u32 = 0;
    while (or_ticks_it.next()) |_| {
        or_ticks_count += 1;
    }
    try expect(or_ticks_count == 2);

    const q_or3_ticks = try app.QueryF(
        struct { entity: Entity },
        .Or3(.Added(Foo), .Changed(Bar), .With(Baz)),
    ).fromWorld(world);
    var or3_ticks_it = q_or3_ticks.iter();
    var or3_ticks_count: u32 = 0;
    while (or3_ticks_it.next()) |_| {
        or3_ticks_count += 1;
    }
    try expect(or3_ticks_count == 3);
}

test "scene codec exports only registered component codecs" {
    const Foo = struct { n: i32 };
    const Bar = struct { n: i32 };

    const app = App(.{});
    var src = try app.init(std.testing.allocator, testIo());
    defer src.deinit();
    var dst = try app.init(std.testing.allocator, testIo());
    defer dst.deinit();

    const foo_codec = struct {
        fn serialize(foo: *const Foo, w: *std.Io.Writer) !void {
            try w.writeInt(i32, foo.n, .little);
        }

        fn deserialize(foo: *Foo, _: std.mem.Allocator, r: *std.Io.Reader) !void {
            foo.* = .{ .n = try r.takeInt(i32, .little) };
        }
    };

    try src.registerComponentCodec(Foo, "Foo", foo_codec.serialize, foo_codec.deserialize);
    try dst.registerComponentCodec(Foo, "Foo", foo_codec.serialize, foo_codec.deserialize);

    const scene_impl = struct {
        fn write(_: *anyopaque, event: app.SceneWriteEvent, w: *std.Io.Writer) !void {
            switch (event) {
                .begin_scene => try w.writeByte('S'),
                .end_scene => try w.writeByte('s'),
                .begin_entity => |entity| {
                    try w.writeByte('E');
                    try w.writeInt(u64, @intFromEnum(entity), .little);
                },
                .end_entity => try w.writeByte('e'),
                .begin_component => |header| {
                    try w.writeByte('C');
                    try w.writeInt(u32, header.hash, .little);
                    try w.writeInt(u32, @intCast(header.size), .little);
                },
                .end_component => try w.writeByte('c'),
                .begin_resource => |header| {
                    try w.writeByte('R');
                    try w.writeInt(u32, header.hash, .little);
                    try w.writeInt(u32, @intCast(header.size), .little);
                },
                .end_resource => try w.writeByte('r'),
            }
        }

        fn read(_: *anyopaque, r: *std.Io.Reader) !app.SceneReadEvent {
            return switch (try r.takeByte()) {
                'S' => .begin_scene,
                's' => .end_scene,
                'E' => .{ .begin_entity = @enumFromInt(try r.takeInt(u64, .little)) },
                'e' => .end_entity,
                'C' => .{ .begin_component = .{
                    .hash = try r.takeInt(u32, .little),
                    .name = "",
                    .size = try r.takeInt(u32, .little),
                } },
                'c' => .end_component,
                'R' => .{ .begin_resource = .{
                    .hash = try r.takeInt(u32, .little),
                    .name = "",
                    .size = try r.takeInt(u32, .little),
                } },
                'r' => .end_resource,
                else => error.MalformedScene,
            };
        }

        fn skip(_: *anyopaque, header: app.ComponentHeader, r: *std.Io.Reader) !void {
            try r.discardAll(header.size);
        }

        fn skipResource(_: *anyopaque, header: app.ResourceHeader, r: *std.Io.Reader) !void {
            try r.discardAll(header.size);
        }
    };

    var scene_state: u8 = 0;
    const scene = app.SceneCodec{
        .ptr = &scene_state,
        .writeEvent = scene_impl.write,
        .readEvent = scene_impl.read,
        .skipComponentPayload = scene_impl.skip,
        .skipResourcePayload = scene_impl.skipResource,
    };

    const entity = src.nextEntityId();
    try src.components.add(src.memtator.world(), 0, entity, Foo{ .n = 42 });
    try src.components.add(src.memtator.world(), 0, entity, Bar{ .n = 99 });

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try src.exportEntity(entity, &aw.writer, scene);

    var reader: std.Io.Reader = .fixed(aw.writer.buffered());
    const imported = Entity.new(77);
    try dst.importEntity(imported, &reader, scene);

    const foo = dst.components.getSingle(imported, Foo).?;
    try expect(foo.n == 42);
    try expect(dst.components.getSingle(imported, Bar) == null);
}

test "scene codec exports entities before registered resources" {
    const Foo = struct { n: i32 };
    const Res = struct { n: i32 };
    const OtherRes = struct { n: i32 };

    const app = App(.{});
    var src = try app.init(std.testing.allocator, testIo());
    defer src.deinit();
    var dst = try app.init(std.testing.allocator, testIo());
    defer dst.deinit();

    const i32_codec = struct {
        fn serializeFoo(foo: *const Foo, w: *std.Io.Writer) !void {
            try w.writeInt(i32, foo.n, .little);
        }

        fn deserializeFoo(foo: *Foo, _: std.mem.Allocator, r: *std.Io.Reader) !void {
            foo.* = .{ .n = try r.takeInt(i32, .little) };
        }

        fn serializeRes(res: *const Res, w: *std.Io.Writer) !void {
            try w.writeInt(i32, res.n, .little);
        }

        fn deserializeRes(res: *Res, _: std.mem.Allocator, r: *std.Io.Reader) !void {
            res.* = .{ .n = try r.takeInt(i32, .little) };
        }
    };

    try src.registerComponentCodec(Foo, "Foo", i32_codec.serializeFoo, i32_codec.deserializeFoo);
    try dst.registerComponentCodec(Foo, "Foo", i32_codec.serializeFoo, i32_codec.deserializeFoo);
    try src.registerResourceCodec(Res, "Res", i32_codec.serializeRes, i32_codec.deserializeRes);
    try dst.registerResourceCodec(Res, "Res", i32_codec.serializeRes, i32_codec.deserializeRes);

    const scene_impl = struct {
        fn write(_: *anyopaque, event: app.SceneWriteEvent, w: *std.Io.Writer) !void {
            switch (event) {
                .begin_scene => try w.writeByte('S'),
                .end_scene => try w.writeByte('s'),
                .begin_entity => |entity| {
                    try w.writeByte('E');
                    try w.writeInt(u64, @intFromEnum(entity), .little);
                },
                .end_entity => try w.writeByte('e'),
                .begin_component => |header| {
                    try w.writeByte('C');
                    try w.writeInt(u32, header.hash, .little);
                    try w.writeInt(u32, @intCast(header.size), .little);
                },
                .end_component => try w.writeByte('c'),
                .begin_resource => |header| {
                    try w.writeByte('R');
                    try w.writeInt(u32, header.hash, .little);
                    try w.writeInt(u32, @intCast(header.size), .little);
                },
                .end_resource => try w.writeByte('r'),
            }
        }

        fn read(_: *anyopaque, r: *std.Io.Reader) !app.SceneReadEvent {
            return switch (try r.takeByte()) {
                'S' => .begin_scene,
                's' => .end_scene,
                'E' => .{ .begin_entity = @enumFromInt(try r.takeInt(u64, .little)) },
                'e' => .end_entity,
                'C' => .{ .begin_component = .{
                    .hash = try r.takeInt(u32, .little),
                    .name = "",
                    .size = try r.takeInt(u32, .little),
                } },
                'c' => .end_component,
                'R' => .{ .begin_resource = .{
                    .hash = try r.takeInt(u32, .little),
                    .name = "",
                    .size = try r.takeInt(u32, .little),
                } },
                'r' => .end_resource,
                else => error.MalformedScene,
            };
        }

        fn skipComponent(_: *anyopaque, header: app.ComponentHeader, r: *std.Io.Reader) !void {
            try r.discardAll(header.size);
        }

        fn skipResource(_: *anyopaque, header: app.ResourceHeader, r: *std.Io.Reader) !void {
            try r.discardAll(header.size);
        }
    };

    var scene_state: u8 = 0;
    const scene = app.SceneCodec{
        .ptr = &scene_state,
        .writeEvent = scene_impl.write,
        .readEvent = scene_impl.read,
        .skipComponentPayload = scene_impl.skipComponent,
        .skipResourcePayload = scene_impl.skipResource,
    };

    const entity = src.nextEntityId();
    try src.components.add(src.memtator.world(), 0, entity, Foo{ .n = 7 });
    try src.addResource(Res{ .n = 123 });
    try src.addResource(OtherRes{ .n = 999 });

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try src.exportScene(&aw.writer, scene, Foo);
    const bytes = aw.writer.buffered();

    try expect(bytes[0] == 'S');
    try expect(bytes[1] == 'E');
    try expect(bytes[25] == 'R');
    try expect(bytes[39] == 's');

    var reader: std.Io.Reader = .fixed(bytes);
    try dst.importScene(&reader, scene);

    const foo = dst.components.getSingle(entity, Foo).?;
    try expect(foo.n == 7);

    const res = try dst.resource(Res);
    try expect(res.n == 123);
    try expect(dst.resource(OtherRes) == EcsError.ResourceNotFound);
}
