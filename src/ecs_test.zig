const std = @import("std");
const e = @import("ecs.zig");

const expect = std.testing.expect;
const Entity = e.Entity;
const ArchType = e.ArchType;
const App = e.App;
const EcsError = e.EcsError;

// -------------------------------------
// tests
test "ecs" {
    const Foo = struct { n: i32 };
    const Bar = struct { n: i32 };
    const Baz = struct { n: i32 };

    const app = App(.{});
    var ecs: app = undefined;
    try ecs.init(std.testing.allocator);
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

    const q1 = try app.Query(.{Foo}).fromWorld(&ecs);
    var viewIter = q1.iterQ(struct { entity: Entity, foo: *const Foo });
    var count: u32 = 0;

    while (viewIter.next()) |en| {
        try expect(en.foo.n == 1);
        count += 1;
    }

    try expect(count == 1);

    const cmd = ecs.getCommands();
    try cmd.despawn(ent2);

    ecs.update();

    const q2 = try app.Query(.{ Baz, Foo }).fromWorld(&ecs);
    var bazIter = q2.iterQ(struct { b: *const Baz, f: *const Foo });
    count = 0;
    while (bazIter.next()) |en| {
        try expect(en.b.n == 11);
        count += 1;
    }

    try expect(count == 1);
}

test "commands" {
    const Foo = struct { n: i32 };

    var ecs: App(.{}) = undefined;
    try ecs.init(std.testing.allocator);
    defer ecs.deinit();

    const cmd = ecs.getCommands();
    _ = try cmd.spawn(.{Foo{ .n = 69 }});

    ecs.update();
    try expect(ecs.entities.count == 1);

    const q = try App(.{}).Query(.{Foo}).fromWorld(&ecs);
    var view = q.iterQ(struct { entity: Entity, foo: *const Foo });

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
    var world: App(.{}) = undefined;
    try world.init(std.testing.allocator);
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
            query: a.Query(.{Foo}),
            bar: a.ResMut(Bar),
            liz: e.Local(Liz),
        ) EcsError!void {
            _ = try c.spawn(.{Foo{ .i = 21 }});
            try expect(liz.inner.i == 0);

            var it = query.iterQ(struct { foo: *const Foo });
            const en = it.next().?;
            try expect(en.foo.i == 69);
            try expect(bar.inner.i == 420);
        }
    }).sys_test;

    const sys2 = (struct {
        fn sys_test(
            c: a.Commands,
            query: a.Query(.{ Foo, e.Mut(Too) }),
            bar: a.Res(Bar),
            liz: e.Local(Liz),
        ) EcsError!void {
            _ = try c.spawn(.{Foo{ .i = 22 }});

            var it = query.iterQ(struct { foo: *const Foo, too: *Too });

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
        try world.systems.runPar(Schedule.update, &world);
        world.update();
    }

    // try expect(world.entityCount() == 21);
}

test "local" {
    var world: App(.{}) = undefined;
    try world.init(std.testing.allocator);
    defer world.deinit();
}

test "test_resource" {
    const TestRes = struct {
        a: u32 = 0,
    };

    const MissingRes = struct {};

    const res = TestRes{ .a = 69 };

    var world: App(.{}) = undefined;
    try world.init(std.testing.allocator);
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
    var world: app = undefined;
    try world.init(std.testing.allocator);
    defer world.deinit();
    const gpa = world.memtator.world();

    const cmd = world.getCommands();

    var list = std.ArrayList(Entity){};
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

    const q = try app.Query(.{Foo}).fromWorld(&world);
    var it = q.iterQ(struct { foo: *const Foo });
    while (it.next()) |en| {
        std.debug.print("THIS SHOULD NOT HAPPEN {any}\n", .{en});
    }

    try expect(world.entityCount() == 0);
}
