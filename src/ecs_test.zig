const std = @import("std");
const e = @import("ecs.zig");

const expect = std.testing.expect;
const Entity = e.Entity;
const ArchRegistry = e.ArchRegistry;
const ArchType = e.ArchType;
const App = e.App;
const EcsError = e.EcsError;

// test "archtype_registry" {
//     const C1 = struct {
//         a: u32 = 0,
//     };
//
//     const C2 = struct {
//         a: u32 = 0,
//         b: u32 = 0,
//     };
//
//     const C3 = struct {
//         a: u32 = 0,
//         b: u32 = 0,
//         c: u32 = 0,
//     };
//
//     const Tag = struct {};
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//
//     var reg = ArchRegistry(512){};
//     const entity = Entity.new(0);
//     const entity2 = Entity.new(1);
//
//     for (0..8000) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i + 5);
//         try reg.add(alloc, 0, ent, C2{ .a = 420 + i });
//     }
//
//     for (0..8000) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i + 5);
//         try reg.add(alloc, 0, ent, C2{ .a = 420 + i });
//     }
//
//     for (0..8000) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i + 5);
//         try reg.add(alloc, 0, ent, C3{ .a = 420 + i });
//     }
//
//     for (0..8000) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i + 5);
//         try reg.remove(alloc, ent, C3);
//     }
//
//     for (0..8000) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i + 5);
//         try reg.add(alloc, 0, ent, C3{ .a = 420 + i });
//         try reg.add(alloc, 0, ent, Tag{});
//     }
//
//     try reg.add(alloc, 0, entity, C2{ .a = 420 });
//     try reg.add(alloc, 0, entity, C1{ .a = 69 });
//     try reg.add(alloc, 0, entity, C3{ .a = 42069 });
//     try reg.add(alloc, 0, entity2, C2{ .a = 12 });
//     try reg.add(alloc, 0, entity2, C1{ .a = 1 });
//     try reg.add(alloc, 0, entity2, Tag{});
//
//     // add same comp
//     for (0..100) |i| {
//         try reg.add(alloc, 0, entity2, C1{ .a = @intCast(i) });
//     }
//
//     try expect(reg.archtypes.items.len == 6);
//     try reg.remove(alloc, entity, C3);
// }

// test "archtype_registry_bundle" {
//     const C1 = struct {
//         a: u32 = 0,
//     };
//
//     const C2 = struct {
//         a: u32 = 0,
//         b: u32 = 55,
//     };
//
//     const C3 = struct {
//         a: u32 = 0,
//         b: u32 = 0,
//         c: u32 = 69,
//     };
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//
//     var reg = ArchRegistry(64){};
//
//     for (0..100) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i);
//         try reg.addBundle(alloc, 0, ent, .{C1{ .a = 69 }});
//     }
//
//     for (0..100) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i);
//         try reg.addBundle(alloc, 0, ent, .{ C2{ .b = i }, C3{ .c = i } });
//     }
//
//     for (0..100) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i);
//         try reg.addBundle(alloc, 0, ent, .{ C1{ .a = i }, C3{ .c = i } });
//     }
//
//     try expect(reg.entity_lookup.size == 100);
//
//     for (0..100) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i);
//
//         const c1 = reg.getSingle(0, ent, C1);
//         const c2 = reg.getSingle(0, ent, C2);
//         const c3 = reg.getSingle(0, ent, C3);
//
//         try expect(c1.?.a == i);
//         try expect(c2.?.b == i);
//         try expect(c3.?.c == i);
//     }
//
//     for (0..100) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i);
//         try reg.remove(alloc, ent, C2);
//     }
//
//     for (0..100) |k| {
//         const i: u32 = @intCast(k);
//         const ent = Entity.new(i);
//
//         const c1 = reg.getSingle(0, ent, C1);
//         const c2 = reg.getSingle(0, ent, C2);
//         const c3 = reg.getSingle(0, ent, C3);
//
//         try expect(c1.?.a == i);
//         try expect(c2 == null);
//         try expect(c3.?.c == i);
//     }
// }

// test "archtype_migration_with_multiple_entities" {
//     const C1 = struct { a: u32 };
//     const C2 = struct { b: u32 };
//     const C3 = struct { c: u32 };
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//
//     var reg = ArchRegistry(512){};
//
//     // Create 3 entities all with C1 and C2 components
//     const entity1 = Entity.new(1);
//     const entity2 = Entity.new(2);
//     const entity3 = Entity.new(3);
//
//     try reg.add(alloc, 0, entity1, C1{ .a = 100 });
//     try reg.add(alloc, 0, entity1, C2{ .b = 200 });
//
//     try reg.add(alloc, 0, entity2, C1{ .a = 101 });
//     try reg.add(alloc, 0, entity2, C2{ .b = 201 });
//
//     try reg.add(alloc, 0, entity3, C1{ .a = 102 });
//     try reg.add(alloc, 0, entity3, C2{ .b = 202 });
//
//     // All 3 entities should be in the same archetype (C1+C2)
//     var c1c2_count: u32 = 0;
//     for (reg.archtypes.items) |*arch| {
//         // Count entities in the C1+C2 archetype
//         if (arch.entity_lookup.size == 3) {
//             c1c2_count = @intCast(arch.entity_lookup.size);
//
//             // Verify data integrity before migration
//             const ent1_c1 = try arch.getSingle(0, entity1, C1);
//             const ent1_c2 = try arch.getSingle(0, entity1, C2);
//             try expect(ent1_c1.a == 100);
//             try expect(ent1_c2.b == 200);
//
//             const ent2_c1 = try arch.getSingle(0, entity2, C1);
//             const ent2_c2 = try arch.getSingle(0, entity2, C2);
//             try expect(ent2_c1.a == 101);
//             try expect(ent2_c2.b == 201);
//
//             const ent3_c1 = try arch.getSingle(0, entity3, C1);
//             const ent3_c2 = try arch.getSingle(0, entity3, C2);
//             try expect(ent3_c1.a == 102);
//             try expect(ent3_c2.b == 202);
//         }
//     }
//     try expect(c1c2_count == 3);
//
//     // Now add C3 to entity2 (middle entity) - this should trigger extendTo
//     try reg.add(alloc, 0, entity2, C3{ .c = 301 });
//
//     // After migration, verify data integrity
//     // entity1 and entity3 should remain in C1+C2 archetype
//     // entity2 should be in C1+C2+C3 archetype
//
//     var found_c1c2_arch = false;
//     var found_c1c2c3_arch = false;
//
//     for (reg.archtypes.items) |*arch| {
//         if (arch.entity_lookup.size == 2) {
//             // Should be the C1+C2 archetype with entity1 and entity3
//             found_c1c2_arch = true;
//
//             // Verify the remaining entities have correct data
//             var found_entity1 = false;
//             var found_entity3 = false;
//
//             for (arch.entities.items) |ent| {
//                 if (std.meta.eql(ent, entity1)) {
//                     found_entity1 = true;
//                     const c1 = arch.getSingle(0, entity1, C1).?;
//                     const c2 = arch.getSingle(0, entity1, C2).?;
//                     try expect(c1.a == 100);
//                     try expect(c2.b == 200);
//                 } else if (std.meta.eql(ent, entity3)) {
//                     found_entity3 = true;
//                     const c1 = arch.getSingle(0, entity3, C1).?;
//                     const c2 = arch.getSingle(0, entity3, C2).?;
//                     try expect(c1.a == 102);
//                     try expect(c2.b == 202);
//                 }
//             }
//
//             try expect(found_entity1);
//             try expect(found_entity3);
//         } else if (arch.entities.items.len == 1) {
//             // Should be the C1+C2+C3 archetype with entity2
//             const ent = arch.entities.items[0];
//             if (std.meta.eql(ent, entity2)) {
//                 found_c1c2c3_arch = true;
//
//                 const c1 = arch.getSingle(0, entity2, C1).?;
//                 const c2 = arch.getSingle(0, entity2, C2).?;
//                 const c3 = arch.getSingle(0, entity2, C3).?;
//                 try expect(c1.a == 101);
//                 try expect(c2.b == 201);
//                 try expect(c3.c == 301);
//             }
//         }
//     }
//
//     try expect(found_c1c2_arch);
//     try expect(found_c1c2c3_arch);
// }

// test "archtype_migration_stress_test" {
//     const Transform = struct { x: f32, y: f32 };
//     const Sprite = struct { id: u32 };
//     const Health = struct { hp: f32 };
//     const Physics = struct { vel_x: f32, vel_y: f32 };
//
//     var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
//     defer arena.deinit();
//     const alloc = arena.allocator();
//
//     var reg = ArchRegistry(512){};
//
//     // Create many entities with Transform + Sprite
//     const num_entities = 100;
//     var entities: [num_entities]Entity = undefined;
//
//     for (0..num_entities) |i| {
//         entities[i] = Entity{ .idx = @intCast(i), .gen = 0 };
//         try reg.add(alloc, 0, entities[i], Transform{ .x = @floatFromInt(i), .y = @floatFromInt(i * 2) });
//         try reg.add(alloc, 0, entities[i], Sprite{ .id = @intCast(i + 1000) });
//     }
//
//     // Verify all entities are in the same archetype
//     var transform_sprite_count: u32 = 0;
//     for (reg.archtypes.items) |*arch| {
//         if (arch.entities.items.len == num_entities) {
//             transform_sprite_count = @intCast(arch.entities.items.len);
//
//             // Verify some entities have correct data
//             const t0 = arch.getSingle(0, entities[0], Transform).?;
//             const s0 = arch.getSingle(0, entities[0], Sprite).?;
//             try expect(t0.x == 0.0);
//             try expect(s0.id == 1000);
//
//             const t50 = arch.getSingle(0, entities[50], Transform).?;
//             const s50 = arch.getSingle(0, entities[50], Sprite).?;
//             try expect(t50.x == 50.0);
//             try expect(s50.id == 1050);
//
//             const t99 = arch.getSingle(0, entities[99], Transform).?;
//             const s99 = arch.getSingle(0, entities[99], Sprite).?;
//             try expect(t99.x == 99.0);
//             try expect(s99.id == 1099);
//         }
//     }
//     try expect(transform_sprite_count == num_entities);
//
//     // Now add Health component to multiple entities in different orders
//     // This should trigger multiple extendTo operations
//     try reg.add(alloc, 0, entities[25], Health{ .hp = 100.0 }); // middle entity
//     try reg.add(alloc, 0, entities[0], Health{ .hp = 100.0 }); // first entity
//     try reg.add(alloc, 0, entities[99], Health{ .hp = 100.0 }); // last entity
//     try reg.add(alloc, 0, entities[50], Health{ .hp = 100.0 }); // another middle entity
//
//     // Then add Physics to some entities (creating different archetypes)
//     try reg.add(alloc, 0, entities[25], Physics{ .vel_x = 1.0, .vel_y = 2.0 });
//     try reg.add(alloc, 0, entities[50], Physics{ .vel_x = 3.0, .vel_y = 4.0 });
//
//     // Verify data integrity across all archetypes
//     var total_entities_found: u32 = 0;
//
//     for (reg.archtypes.items) |*arch| {
//         total_entities_found += @intCast(arch.entities.items.len);
//
//         // Check each entity in this archetype
//         for (arch.entities.items) |ent| {
//             const transform = arch.getSingle(0, ent, Transform).?;
//             const sprite = arch.getSingle(0, ent, Sprite).?;
//
//             // Verify transform data matches entity index
//             try expect(transform.x == @as(f32, @floatFromInt(ent.idx)));
//             try expect(transform.y == @as(f32, @floatFromInt(ent.idx * 2)));
//
//             // Verify sprite data matches entity index
//             try expect(sprite.id == ent.idx + 1000);
//
//             // If entity has Health component, verify it
//             if (arch.getSingle(0, ent, Health)) |health| {
//                 try expect(health.hp == 100.0);
//             }
//
//             // If entity has Physics component, verify it
//             if (arch.getSingle(0, ent, Physics)) |physics| {
//                 if (ent.idx == 25) {
//                     try expect(physics.vel_x == 1.0);
//                     try expect(physics.vel_y == 2.0);
//                 } else if (ent.idx == 50) {
//                     try expect(physics.vel_x == 3.0);
//                     try expect(physics.vel_y == 4.0);
//                 }
//             }
//         }
//     }
//
//     // Should still have all entities accounted for
//     try expect(total_entities_found == num_entities);
// }
//
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

    try ecs.archtypes.add(alloc, 0, ent1, Foo{ .n = 1 });
    try ecs.archtypes.add(alloc, 0, ent1, Baz{ .n = 11 });
    try ecs.archtypes.add(alloc, 0, ent1, Bar{ .n = 22 });
    try ecs.archtypes.add(alloc, 0, ent2, Foo{ .n = 2 });
    try ecs.archtypes.add(alloc, 0, ent2, Bar{ .n = 22 });

    try ecs.archtypes.remove(alloc, ent2, Bar);
    try ecs.archtypes.remove(alloc, ent2, Foo);

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

// test "weapon_style_children_with_transform" {
//     // Simulates the enemy ship + weapon scenario more closely
//     const Transform = struct { x: f32 = 0.0, y: f32 = 0.0, z: f32 = 0.0 };
//     const Health = struct { value: i32 = 10 };
//     const Weapon = struct { damage: i32 = 5 };
//     const WeaponAi = struct { range: f32 = 100.0 };
//
//     var world: App(.{}) = undefined;
//     try world.init(std.testing.allocator);
//     defer world.deinit();
//
//     const cmd = world.getCommands();
//     const gpa = world.memtator.world();
//
//     // Spawn enemy ships with weapons as children (like in enemy.zig)
//     var ships = std.ArrayList(Entity){};
//
//     for (0..100) |i| {
//         const ship = try cmd.spawn(.{
//             Transform{ .x = @floatFromInt(i * 10), .y = @floatFromInt(i * 10), .z = 1.0 },
//             Health{ .value = 2 },
//             // Child weapon tuple
//             .{
//                 Transform{ .x = 0.0, .y = 0.0, .z = 0.0 }, // Weapon at local origin relative to ship
//                 Weapon{ .damage = 1 },
//                 WeaponAi{ .range = 300.0 },
//             },
//         });
//
//         try ships.append(gpa,ship);
//     }
//
//     world.update();
//
//     // Verify initial setup
//     const parent_query = try App(.{}).Query(.{ Transform, Health }).fromWorld(&world);
//     var parent_iter = parent_query.iterQ(struct { entity: Entity, transform: *const Transform, health: *const Health });
//
//     var parent_count: u32 = 0;
//     while (parent_iter.next()) |parent| {
//         parent_count += 1;
//
//         // Verify parent position
//         try expect(parent.transform.z == 1.0);
//         try expect(parent.health.value == 2);
//     }
//     try expect(parent_count == 100);
//
//     // Verify children exist
//     const weapon_query = try App(.{}).Query(.{ Transform, Weapon, WeaponAi }).fromWorld(&world);
//     var weapon_iter = weapon_query.iterQ(struct { entity: Entity, transform: *const Transform, weapon: *const Weapon });
//
//     var weapon_count: u32 = 0;
//     while (weapon_iter.next()) |weapon| {
//         weapon_count += 1;
//
//         // Verify weapon initial transform
//         try expect(weapon.transform.x == 0.0);
//         try expect(weapon.transform.y == 0.0);
//         try expect(weapon.transform.z == 0.0);
//         try expect(weapon.weapon.damage == 1);
//     }
//     try expect(weapon_count == 100);
//
//     // Kill half the ships (like in health system)
//     for (ships.items[0..50]) |ship| {
//         try cmd.despawn(ship);
//     }
//
//     // CRITICAL: Check weapon positions BEFORE world.update() processes despawns
//     // This simulates what happens when rendering system runs before despawn commands are processed
//     var pre_despawn_weapon_iter = weapon_query.iterQ(struct { entity: Entity, transform: *const Transform, weapon: *const Weapon });
//     var pre_despawn_count: u32 = 0;
//     while (pre_despawn_weapon_iter.next()) |weapon| {
//         pre_despawn_count += 1;
//
//         // All weapons should still be at their original positions (0,0,0)
//         // None should be corrupted or moved to origin yet
//         try expect(weapon.transform.x == 0.0);
//         try expect(weapon.transform.y == 0.0);
//         try expect(weapon.transform.z == 0.0);
//     }
//     try expect(pre_despawn_count == 100); // All weapons still exist before update
//
//     world.update(); // Process despawn commands
//
//     // After despawn, verify no entities exist at corrupted positions
//     var post_despawn_weapon_iter = weapon_query.iterQ(struct { entity: Entity, transform: *const Transform, weapon: *const Weapon });
//     var post_despawn_count: u32 = 0;
//     while (post_despawn_weapon_iter.next()) |weapon| {
//         post_despawn_count += 1;
//
//         // Remaining weapons should still have valid transforms
//         try expect(weapon.transform.x == 0.0);
//         try expect(weapon.transform.y == 0.0);
//         try expect(weapon.transform.z == 0.0);
//     }
//     try expect(post_despawn_count == 50); // Only half remain
//
//     // Verify total entity count
//     try expect(world.entityCount() == 100); // 50 ships + 50 weapons
// }
//
// test "children_despawn_with_component_corruption_check" {
//     // Test specifically for component data corruption during despawn
//     const Position = struct { x: f32, y: f32, z: f32 };
//     const Identity = struct { id: u32 };
//     const ChildMarker = struct {};
//
//     var world: App(.{}) = undefined;
//     try world.init(std.testing.allocator);
//     defer world.deinit();
//
//     const cmd = world.getCommands();
//
//     // Create parents with children, each with unique positions
//     var parents = std.ArrayList(Entity).init(world.memtator.world());
//
//     for (0..20) |i| {
//         const parent = try cmd.spawn(.{
//             Position{ .x = @floatFromInt(i), .y = @floatFromInt(i * 2), .z = 1.0 },
//             Identity{ .id = @intCast(i) },
//             // Child with specific position
//             .{
//                 Position{ .x = @floatFromInt(i + 100), .y = @floatFromInt(i + 200), .z = 0.0 },
//                 Identity{ .id = @intCast(i + 1000) },
//                 ChildMarker{},
//             },
//         });
//
//         try parents.append(parent);
//     }
//
//     world.update();
//
//     // Collect all child positions before despawn
//     const child_query = try App(.{}).Query(.{ Position, Identity, ChildMarker }).fromWorld(&world);
//     var child_positions = std.ArrayList(struct { x: f32, y: f32, id: u32 }).init(world.memtator.world());
//
//     var pre_iter = child_query.iterQ(struct { pos: *const Position, identity: *const Identity });
//     while (pre_iter.next()) |child| {
//         try child_positions.append(.{ .x = child.pos.x, .y = child.pos.y, .id = child.identity.id });
//     }
//     try expect(child_positions.items.len == 20);
//
//     // Despawn every other parent (creating gaps in the archetype)
//     for (0..10) |i| {
//         try cmd.despawn(parents.items[i * 2]);
//     }
//
//     // BEFORE world.update(), check that children still have valid positions
//     var mid_iter = child_query.iterQ(struct { entity: Entity, pos: *const Position, identity: *const Identity });
//     var mid_count: u32 = 0;
//     while (mid_iter.next()) |child| {
//         mid_count += 1;
//
//         // Child positions should not be corrupted/reset to origin during despawn process
//         const expected_x = @as(f32, @floatFromInt(child.identity.id - 1000 + 100));
//         const expected_y = @as(f32, @floatFromInt(child.identity.id - 1000 + 200));
//
//         // This is where we might catch the (0,0,0) blinking issue
//         if (child.pos.x == 0.0 and child.pos.y == 0.0 and child.pos.z == 0.0) {
//             std.debug.print("FOUND CORRUPTION: Child entity {} has position (0,0,0) when it should be ({d},{d},0)\n", .{ child.entity.idx, expected_x, expected_y });
//             try expect(false); // Fail if we find corruption
//         }
//
//         try expect(child.pos.x == expected_x);
//         try expect(child.pos.y == expected_y);
//         try expect(child.pos.z == 0.0);
//     }
//     try expect(mid_count == 20); // All children still exist before update
//
//     world.update(); // Process despawn commands
//
//     // After despawn, verify remaining children have correct data
//     var post_iter = child_query.iterQ(struct { pos: *const Position, identity: *const Identity });
//     var post_count: u32 = 0;
//     while (post_iter.next()) |child| {
//         post_count += 1;
//
//         const expected_x = @as(f32, @floatFromInt(child.identity.id - 1000 + 100));
//         const expected_y = @as(f32, @floatFromInt(child.identity.id - 1000 + 200));
//
//         try expect(child.pos.x == expected_x);
//         try expect(child.pos.y == expected_y);
//         try expect(child.pos.z == 0.0);
//     }
//     try expect(post_count == 10); // Half the children should remain
//     try expect(world.entityCount() == 20); // 10 parents + 10 children
// }
//
// test "rapid_despawn_children_stress" {
//     // Stress test to expose timing issues in despawn
//     const Transform = struct { x: f32, y: f32, z: f32 };
//     const Marker = struct { value: u32 };
//
//     var world: App(.{}) = undefined;
//     try world.init(std.testing.allocator);
//     defer world.deinit();
//
//     const cmd = world.getCommands();
//
//     // Create many entities with children
//     for (0..100) |batch| {
//         for (0..10) |i| {
//             const parent_id = batch * 10 + i;
//             _ = try cmd.spawn(.{
//                 Transform{ .x = @floatFromInt(parent_id), .y = 0.0, .z = 1.0 },
//                 Marker{ .value = @intCast(parent_id) },
//                 // Multiple children per parent
//                 .{
//                     Transform{ .x = @floatFromInt(parent_id + 1000), .y = 1.0, .z = 0.0 },
//                     Marker{ .value = @intCast(parent_id + 1000) },
//                 },
//                 .{
//                     Transform{ .x = @floatFromInt(parent_id + 2000), .y = 2.0, .z = 0.0 },
//                     Marker{ .value = @intCast(parent_id + 2000) },
//                 },
//             });
//         }
//
//         world.update(); // Process batch
//
//         // Immediately query and despawn some entities
//         const parent_query = try App(.{}).Query(.{ Transform, Marker }).fromWorld(&world);
//         var parent_iter = parent_query.iterQ(struct { entity: Entity, transform: *const Transform, marker: *const Marker });
//
//         while (parent_iter.next()) |parent| {
//             if (parent.transform.z == 1.0 and parent.marker.value % 3 == 0) {
//                 try cmd.despawn(parent.entity);
//             }
//         }
//
//         // Check children positions before despawn processing
//         const child_query = try App(.{}).QueryFiltered(.{ Transform, Marker }, .{App(.{}).WithOut(Transform)}).fromWorld(&world);
//         var child_iter = child_query.iterQ(struct { entity: Entity, transform: *const Transform, marker: *const Marker });
//
//         while (child_iter.next()) |child| {
//             // Verify child hasn't been corrupted to (0,0,0)
//             if (child.transform.z == 0.0) { // This is a child
//                 const expected_x = @as(f32, @floatFromInt(child.marker.value));
//                 if (child.transform.x != expected_x) {
//                     std.debug.print("Child corruption detected: entity {} has x={d}, expected x={d}\n", .{ child.entity.idx, child.transform.x, expected_x });
//                     try expect(false);
//                 }
//             }
//         }
//
//         world.update(); // Process despawns
//     }
//
//     // Final verification - no corrupted entities should remain
//     try expect(world.entityCount() > 0);
// }
