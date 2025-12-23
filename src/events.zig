const std = @import("std");
const ecs = @import("ecs.zig");

pub fn EventStore(comptime T: type) type {
    return struct {
        current: std.ArrayListUnmanaged(T) = .{},
        next_frame: std.ArrayListUnmanaged(T) = .{},

        list: std.ArrayList(T) = .{},
        offset: usize = 0,
    };
}

pub fn EventExtension(comptime cfg: ecs.AppDesc) type {
    const App = ecs.App(cfg);
    return struct {
        pub fn EventStorePlugin(comptime T: type, comptime cleanup_schedule: anytype) type {
            return struct {
                pub fn plugin(world: *App) !void {
                    try world.addResource(EventStore(T){});
                    try world.addSystem(cleanup_schedule, &cleanup);
                }

                pub fn cleanup(store: App.ResMut(EventStore(T))) !void {
                    store.inner.current.clearRetainingCapacity();
                    std.mem.swap(std.ArrayListUnmanaged(T), &store.inner.current, &store.inner.next_frame);
                }
            };
        }

        /// **Currently only reads events of the last frame**
        /// TODO: needs proper offset tracking to work accross multiple frames
        pub fn EventReader(comptime T: type) type {
            return struct {
                const Self = @This();
                events: []T,

                pub fn fromLocal(world: *App, _: *ecs.ResourceRegistry(cfg.FlagInt)) !Self {
                    const store = try world.getResource(EventStore(T));
                    return Self{
                        .events = store.current.items,
                    };
                }
            };
        }

        pub fn EventWriter(comptime T: type) type {
            return struct {
                const Self = @This();
                queue: *std.ArrayListUnmanaged(T),
                gpa: std.mem.Allocator,

                pub fn fromWorld(world: *App) !Self {
                    const store = try world.getResource(EventStore(T));
                    return Self{
                        .queue = &store.next_frame,
                        .gpa = world.memtator.world(),
                    };
                }

                pub fn addAccess(app: *App, access: *ecs.Access(cfg.FlagInt)) void {
                    const flag = app.resources.resource_flags.getFlag(EventStore(T));
                    access.res_read_write.insert(flag);
                    access.res_write.insert(flag);
                }

                pub fn send(self: *const Self, event: T) !void {
                    try self.queue.append(self.gpa, event);
                }
            };
        }
    };
}
