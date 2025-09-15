const std = @import("std");
const ecs = @import("ecs.zig");

const assert = std.debug.assert;
const EcsError = ecs.EcsError;
const Entity = ecs.Entity;
const ArchRegistry = ecs.ArchRegistry;
const ArchType = ecs.ArchType;

test "archtest" {
    const expect = std.testing.expect;
    const C1 = struct {
        a: u32 = 69,
    };

    const C2 = struct {
        a: u16 = 1,
        b: u8 = 2,
    };

    const C3 = struct {
        a: u8 = 4,
        b: u12 = 5,
        c: u24 = 6,
    };

    const Tag = struct {};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var arch = ArchType(512){};
    try arch.addComp(alloc, C1, 0);
    try arch.addComp(alloc, C2, 0);
    try arch.addComp(alloc, C3, 0);
    try arch.addComp(alloc, Tag, 0);
    try arch.setCapacity(alloc, 512);

    for (0..21) |i| {
        const ent = Entity{ .idx = @intCast(i) };
        try arch.putSingle(alloc, @intCast(i), ent, C1{ .a = 69 });
        try arch.putSingle(alloc, @intCast(i), ent, C2{ .a = @intCast(i) });
        try arch.putSingle(alloc, @intCast(i), ent, C3{});
        try arch.putSingle(alloc, @intCast(i), ent, Tag{});
    }

    try arch.remove(alloc, Entity{ .idx = 10 });

    for (0..20) |k| {
        const ent = Entity{ .idx = @intCast(k) };

        if (k == 10) {
            try std.testing.expectError(EcsError.EntityNotFound, arch.getSingle(420, ent, C1));
            continue;
        }

        const c1 = try arch.getSingle(420, ent, C1);
        const c2 = try arch.getSingleConst(ent, C2);
        const info = arch.getTickInfo(@intCast(k), arch.getMeta(C1).?);
        try expect(c1.a == 69);
        try expect(c2.a == @as(u16, @intCast(k)));
        try expect(info.changed == 420);

        // std.debug.print("- {d}\n", .{c2.a});
        // std.debug.print("\nres: {d}  changed: {d} added: {d}\n", .{ c1.a, info.changed, info.added });
    }

    try arch.setCapacity(alloc, 1024);

    for (0..20) |k| {
        const ent = Entity{ .idx = @intCast(k) };

        if (k == 10) {
            try std.testing.expectError(EcsError.EntityNotFound, arch.getSingle(420, ent, C1));
            continue;
        }

        const c1 = try arch.getSingleConst(ent, C1);
        const c2 = try arch.getSingleConst(ent, C2);
        const info = arch.getTickInfo(@intCast(k), arch.getMeta(C1).?);

        try expect(c1.a == 69);
        try expect(c2.a == @as(u16, @intCast(k)));
        try expect(info.changed == 420);

        // std.debug.print("- {d}\n", .{c2.a});
        // std.debug.print("\nres: {d}  changed: {d} added: {d}\n", .{ c1.a, info.changed, info.added });
    }

    for (0..20) |k| {
        if (k == 10) {
            continue;
        }

        const q = try arch.getQueryIndex(11, k, struct {
            entity: Entity,
            c1: *const C1,
            c2: *const C2,
            c3: *C3,
        });

        const info = arch.getTickInfo(k, arch.getMeta(C3).?);
        try expect(info.changed == 11);
        try expect(q.c1.a == 69);
        try expect(q.c2.a == @as(u16, @intCast(k)));
    }
}

test "arch_move" {
    const expect = std.testing.expect;
    const C1 = extern struct {
        a: u32 = 69,
        color: @Vector(4, f32) = .{ 55, 33, 11, 1 },
    };

    const C2 = struct {
        a: u16 = 1,
        b: u8 = 2,
    };

    const C3 = struct {
        a: u8 = 4,
        b: u12 = 5,
        c: u24 = 6,
    };

    const C4 = struct {
        a: u64 = 88,
        c: C3 = .{},
        u: [16]u32 = undefined,
        color: @Vector(4, f32) = .{ 55, 33, 11, 1 },
    };

    const Tag = struct {};
    _ = Tag; // autofix
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var src = ArchType(512){};
    try src.addComp(alloc, C1, 0);
    try src.addComp(alloc, C2, 1);
    try src.addComp(alloc, C3, 2);
    try src.setCapacity(alloc, 64);

    var dst = try src.cloneEmpty(alloc);
    try dst.setCapacity(alloc, 64);

    try src.put(alloc, 11, Entity{ .idx = 66 }, .{ C1{}, C2{}, C3{} });
    try src.put(alloc, 11, Entity{ .idx = 64 }, .{ C1{ .a = 12 }, C2{}, C3{} });
    try src.put(alloc, 11, Entity{ .idx = 61 }, .{ C1{ .a = 11 }, C2{}, C3{} });

    {
        const q = try src.getQueryIndex(0, 0, struct { c1: *const C1, c2: *C2, c3: *C3 });
        try expect(q.c1.a == 69 and q.c2.b == 2 and q.c3.c == 6);
    }

    try src.moveTo(alloc, Entity{ .idx = 66 }, &dst);

    const p = try dst.getQueryIndex(0, 0, struct { c1: *const C1, c2: *C2, c3: *C3 });
    try expect(p.c1.a == 69 and p.c2.b == 2 and p.c3.c == 6);

    try expect(src.len == 2);
    try expect(dst.len == 1);

    {
        const q = try src.getQueryIndex(0, 0, struct { c1: *const C1, c2: *C2, c3: *C3 });
        try expect(q.c1.a == 11 and q.c2.b == 2 and q.c3.c == 6);
    }

    var dst2 = try dst.cloneEmpty(alloc);
    try dst2.addComp(alloc, C4, 5);
    try dst2.setCapacity(alloc, 512);

    try dst.moveTo(alloc, Entity{ .idx = 66 }, &dst2);

    try dst2.putSingle(alloc, 0, Entity{ .idx = 66 }, C4{});

    {
        const q = try dst2.getQueryIndex(0, 0, struct { c1: *const C1, c2: *C2, c3: *C3, c4: *C4 });
        try expect(q.c1.a == 69 and q.c2.b == 2 and q.c3.c == 6 and q.c4.a == 88);
    }
}

test "arch_registry_progressive_upgrade_downgrade" {
    const expect = std.testing.expect;

    const Position = struct {
        x: f32 = 0.0,
        y: f32 = 0.0,
    };

    const Velocity = struct {
        dx: f32 = 1.0,
        dy: f32 = 1.0,
    };

    const Health = struct {
        hp: u32 = 100,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = ArchRegistry(64){};
    const entity_count = 40; // Smaller count for easier debugging

    // STEP 1: Start with entities that only have Position (minimal archetype)
    for (0..entity_count) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.add(alloc, @intCast(i), entity, Position{ .x = @floatFromInt(i), .y = @floatFromInt(i * 2) });
    }

    // Should have 1 archetype: [Position]
    try expect(registry.archtypes.items.len == 1);

    // STEP 2: UPGRADE - Add Velocity to first half [Position] -> [Position + Velocity]
    for (0..entity_count / 2) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.add(alloc, @intCast(i + 100), entity, Velocity{ .dx = @floatFromInt(i % 5), .dy = @floatFromInt(i % 7) });
    }

    // Should have 2 archetypes: [Position], [Position + Velocity]
    try expect(registry.archtypes.items.len == 2);

    // STEP 3: UPGRADE - Add Health to first quarter [Position + Velocity] -> [Position + Velocity + Health]
    for (0..entity_count / 4) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.add(alloc, @intCast(i + 200), entity, Health{ .hp = @intCast(i + 150) });
    }

    // Should have 3 archetypes: [Position], [Position + Velocity], [Position + Velocity + Health]
    try expect(registry.archtypes.items.len == 3);

    // Verify current state
    for (0..entity_count) |i| {
        const entity = Entity{ .idx = @intCast(i) };

        // All should have Position
        const pos = registry.getSingle(@intCast(i + 300), entity, Position);
        try expect(pos != null);
        try expect(pos.?.x == @as(f32, @floatFromInt(i)));

        if (i < entity_count / 4) {
            // First quarter: [Position + Velocity + Health]
            const vel = registry.getSingle(@intCast(i + 300), entity, Velocity);
            const health = registry.getSingle(@intCast(i + 300), entity, Health);
            try expect(vel != null);
            try expect(health != null);
            try expect(health.?.hp == @as(u32, @intCast(i + 150)));
        } else if (i < entity_count / 2) {
            // Second quarter: [Position + Velocity]
            const vel = registry.getSingle(@intCast(i + 300), entity, Velocity);
            const health = registry.getSingle(@intCast(i + 300), entity, Health);
            try expect(vel != null);
            try expect(health == null);
        } else {
            // Second half: [Position] only
            const vel = registry.getSingle(@intCast(i + 300), entity, Velocity);
            const health = registry.getSingle(@intCast(i + 300), entity, Health);
            try expect(vel == null);
            try expect(health == null);
        }
    }

    // STEP 4: DOWNGRADE - Remove Velocity from some entities [Position + Velocity + Health] -> [Position + Health]
    for (0..entity_count / 8) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.remove(alloc, entity, Velocity);
    }

    // STEP 5: DOWNGRADE - Remove Health from some entities [Position + Velocity + Health] -> [Position + Velocity]
    for (entity_count / 8..entity_count / 4) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.remove(alloc, entity, Health);
    }

    // Verify downgrades worked
    for (0..entity_count) |i| {
        const entity = Entity{ .idx = @intCast(i) };

        if (i < entity_count / 8) {
            // [Position + Health] - Velocity removed
            const vel = registry.getSingle(@intCast(i + 400), entity, Velocity);
            const health = registry.getSingle(@intCast(i + 400), entity, Health);
            try expect(vel == null);
            try expect(health != null);
        } else if (i < entity_count / 4) {
            // [Position + Velocity] - Health removed
            const vel = registry.getSingle(@intCast(i + 400), entity, Velocity);
            const health = registry.getSingle(@intCast(i + 400), entity, Health);
            try expect(vel != null);
            try expect(health == null);
        } else if (i < entity_count / 2) {
            // [Position + Velocity] - unchanged
            const vel = registry.getSingle(@intCast(i + 400), entity, Velocity);
            const health = registry.getSingle(@intCast(i + 400), entity, Health);
            try expect(vel != null);
            try expect(health == null);
        } else {
            // [Position] only - unchanged
            const vel = registry.getSingle(@intCast(i + 400), entity, Velocity);
            const health = registry.getSingle(@intCast(i + 400), entity, Health);
            try expect(vel == null);
            try expect(health == null);
        }
    }
}

test "arch_registry_moveto_add_components" {
    const expect = std.testing.expect;

    const Position = struct {
        x: f32 = 0.0,
        y: f32 = 0.0,
    };

    const Velocity = struct {
        dx: f32 = 1.0,
        dy: f32 = 1.0,
    };

    const Health = struct {
        hp: u32 = 100,
    };

    const Armor = struct {
        defense: u16 = 50,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = ArchRegistry(64){};

    // Create entities with just Position initially
    const entity_count = 100;
    for (0..entity_count) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.add(alloc, @intCast(i), entity, Position{ .x = @floatFromInt(i), .y = @floatFromInt(i * 2) });
    }

    // Verify initial state - should have 1 archetype
    try expect(registry.archtypes.items.len == 1);

    // Add Velocity to first half of entities (should trigger moveTo)
    for (0..entity_count / 2) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.add(alloc, @intCast(i + 100), entity, Velocity{ .dx = @floatFromInt(i % 5), .dy = @floatFromInt(i % 7) });
    }

    // Should now have 2 archetypes: Position, Position+Velocity
    try expect(registry.archtypes.items.len == 2);

    // Add Health to some entities from each group
    for (0..entity_count / 4) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.add(alloc, @intCast(i + 200), entity, Health{ .hp = @intCast(i + 150) });
    }

    for (entity_count / 2..3 * entity_count / 4) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.add(alloc, @intCast(i + 200), entity, Health{ .hp = @intCast(i + 150) });
    }

    // Should now have more archetypes
    try expect(registry.archtypes.items.len >= 3);

    // Add Armor to create even more complex movements
    for (0..entity_count / 8) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.add(alloc, @intCast(i + 300), entity, Armor{ .defense = @intCast(i + 25) });
    }

    // Verify all entities still exist and have correct components
    for (0..entity_count) |i| {
        const entity = Entity{ .idx = @intCast(i) };

        // All entities should still have Position
        const pos = registry.getSingle(@intCast(i + 400), entity, Position);
        try expect(pos != null);
        try expect(pos.?.x == @as(f32, @floatFromInt(i)));
        try expect(pos.?.y == @as(f32, @floatFromInt(i * 2)));

        // First half should have Velocity
        if (i < entity_count / 2) {
            const vel = registry.getSingle(@intCast(i + 400), entity, Velocity);
            try expect(vel != null);
            try expect(vel.?.dx == @as(f32, @floatFromInt(i % 5)));
            try expect(vel.?.dy == @as(f32, @floatFromInt(i % 7)));
        }

        // Quarter should have Health
        if ((i < entity_count / 4) or (i >= entity_count / 2 and i < 3 * entity_count / 4)) {
            const health = registry.getSingle(@intCast(i + 400), entity, Health);
            try expect(health != null);
            try expect(health.?.hp == @as(u32, @intCast(i + 150)));
        }

        // Eighth should have Armor
        if (i < entity_count / 8) {
            const armor = registry.getSingle(@intCast(i + 400), entity, Armor);
            try expect(armor != null);
            try expect(armor.?.defense == @as(u16, @intCast(i + 25)));
        }
    }
}

test "arch_registry_progressive_downgrading" {
    const expect = std.testing.expect;

    const Position = struct {
        x: f32 = 0.0,
        y: f32 = 0.0,
    };

    const Velocity = struct {
        dx: f32 = 1.0,
        dy: f32 = 1.0,
    };

    const Health = struct {
        hp: u32 = 100,
    };

    const Armor = struct {
        defense: u16 = 50,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = ArchRegistry(64){};
    const entity_count = 32; // Smaller for easier tracking

    // STEP 1: Start with entities that have ALL four components (maximal archetype)
    for (0..entity_count) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.addBundle(alloc, @intCast(i), entity, .{ Position{ .x = @floatFromInt(i), .y = @floatFromInt(i * 2) }, Velocity{ .dx = @floatFromInt(i % 5), .dy = @floatFromInt(i % 7) }, Health{ .hp = @intCast(i + 100) }, Armor{ .defense = @intCast(i + 50) } });
    }

    // Should have 1 archetype: [Position + Velocity + Health + Armor]
    try expect(registry.archtypes.items.len == 1);

    // STEP 2: DOWNGRADE - Remove Armor from first quarter: [P+V+H+A] -> [P+V+H]
    for (0..entity_count / 4) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.remove(alloc, entity, Armor);
    }

    // Should have 2 archetypes: [P+V+H+A], [P+V+H]
    try expect(registry.archtypes.items.len == 2);

    // STEP 3: DOWNGRADE - Remove Health from second quarter: [P+V+H+A] -> [P+V+A]
    for (entity_count / 4..entity_count / 2) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.remove(alloc, entity, Health);
    }

    // Should have 3 archetypes: [P+V+H+A], [P+V+H], [P+V+A]
    try expect(registry.archtypes.items.len == 3);

    // STEP 4: DOWNGRADE - Remove Velocity from third quarter: [P+V+H+A] -> [P+H+A]
    for (entity_count / 2..3 * entity_count / 4) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.remove(alloc, entity, Velocity);
    }

    // Should have 4 archetypes: [P+V+H+A], [P+V+H], [P+V+A], [P+H+A]
    try expect(registry.archtypes.items.len == 4);

    // Verify the component states at this point
    for (0..entity_count) |i| {
        const entity = Entity{ .idx = @intCast(i) };

        // All entities should still have Position
        const pos = registry.getSingle(@intCast(i + 300), entity, Position);
        try expect(pos != null);
        try expect(pos.?.x == @as(f32, @floatFromInt(i)));

        if (i < entity_count / 4) {
            // First quarter: [P+V+H] - Armor removed
            try expect(registry.getSingle(@intCast(i + 300), entity, Velocity) != null);
            try expect(registry.getSingle(@intCast(i + 300), entity, Health) != null);
            try expect(registry.getSingle(@intCast(i + 300), entity, Armor) == null);
        } else if (i < entity_count / 2) {
            // Second quarter: [P+V+A] - Health removed
            try expect(registry.getSingle(@intCast(i + 300), entity, Velocity) != null);
            try expect(registry.getSingle(@intCast(i + 300), entity, Health) == null);
            try expect(registry.getSingle(@intCast(i + 300), entity, Armor) != null);
        } else if (i < 3 * entity_count / 4) {
            // Third quarter: [P+H+A] - Velocity removed
            try expect(registry.getSingle(@intCast(i + 300), entity, Velocity) == null);
            try expect(registry.getSingle(@intCast(i + 300), entity, Health) != null);
            try expect(registry.getSingle(@intCast(i + 300), entity, Armor) != null);
        } else {
            // Fourth quarter: [P+V+H+A] - untouched
            try expect(registry.getSingle(@intCast(i + 300), entity, Velocity) != null);
            try expect(registry.getSingle(@intCast(i + 300), entity, Health) != null);
            try expect(registry.getSingle(@intCast(i + 300), entity, Armor) != null);
        }
    }

    // STEP 5: Further downgrading - remove more components to create single-component entities

    // Remove Health and Velocity from first 1/8: [P+V+H] -> [P]
    for (0..entity_count / 8) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.remove(alloc, entity, Health);
        try registry.remove(alloc, entity, Velocity);
    }

    // Remove Velocity and Armor from some in second quarter: [P+V+A] -> [P]
    for (entity_count / 4..entity_count / 4 + entity_count / 8) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.remove(alloc, entity, Velocity);
        try registry.remove(alloc, entity, Armor);
    }

    // Final verification
    for (0..entity_count) |i| {
        const entity = Entity{ .idx = @intCast(i) };

        // All should still have Position
        try expect(registry.getSingle(@intCast(i + 400), entity, Position) != null);

        if (i < entity_count / 8) {
            // [P] only - everything else removed
            try expect(registry.getSingle(@intCast(i + 400), entity, Velocity) == null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Health) == null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Armor) == null);
        } else if (i < entity_count / 4) {
            // [P+V+H] - Only Armor was removed in step 2, these were not touched in step 5
            try expect(registry.getSingle(@intCast(i + 400), entity, Velocity) != null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Health) != null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Armor) == null);
        } else if (i < entity_count / 4 + entity_count / 8) {
            // [P] only - everything else removed
            try expect(registry.getSingle(@intCast(i + 400), entity, Velocity) == null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Health) == null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Armor) == null);
        } else if (i < entity_count / 2) {
            // [P+V+A] - Health was already removed in step 3, other components remain
            try expect(registry.getSingle(@intCast(i + 400), entity, Velocity) != null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Health) == null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Armor) != null);
        } else if (i < 3 * entity_count / 4) {
            // [P+H+A] - Velocity removed
            try expect(registry.getSingle(@intCast(i + 400), entity, Velocity) == null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Health) != null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Armor) != null);
        } else {
            // [P+V+H+A] - untouched
            try expect(registry.getSingle(@intCast(i + 400), entity, Velocity) != null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Health) != null);
            try expect(registry.getSingle(@intCast(i + 400), entity, Armor) != null);
        }
    }

    // Test despawn functionality
    const entities_to_despawn = 4;
    for (0..entities_to_despawn) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try registry.despawn(alloc, entity);
    }

    // Verify despawned entities are gone
    for (0..entities_to_despawn) |i| {
        const entity = Entity{ .idx = @intCast(i) };
        try expect(registry.getSingle(@intCast(i + 500), entity, Position) == null);
    }
}
