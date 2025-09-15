const std = @import("std");
const ecs = @import("ecs.zig");

pub fn StateExtension(comptime cfg: ecs.AppDesc) type {
    const App = ecs.App(cfg);
    const FilterFunc = App.SystemRegistry.ConditionFn;
    return struct {
        pub fn Transition(comptime S: type) type {
            return struct {
                from: S,
                to: S,

                pub fn eq(self: *const @This(), rhs: *const @This()) bool {
                    return self.from == rhs.from and self.to == rhs.to;
                }
            };
        }

        /// # State Resource
        /// holds current state
        pub fn State(comptime S: type) type {
            comptime if (!@typeInfo(S).@"enum".is_exhaustive) @compileError("States must be enums");
            return struct {
                const Self = @This();
                last_transition: Transition(S),
                current: S,

                pub fn set(self: *Self, next: S) void {
                    self.last_transition = .{
                        .from = self.current,
                        .to = next,
                    };
                    self.current = next;
                }

                pub fn new(initial: S) Self {
                    return .{
                        .current = initial,
                        .last_transition = .{ .from = initial, .to = initial },
                    };
                }
            };
        }

        /// # StatePlugin
        /// adds state to resources, registeres scope functions
        /// `Schedule`: provide cleanup schedule
        pub fn StatePlugin(comptime default_state: anytype, comptime Schedule: anytype) type {
            const StateType = @TypeOf(default_state);
            return struct {
                pub fn plugin(world: *App) !void {
                    try world.addResource(State(StateType).new(default_state));
                    try world.addSystemEx(Schedule, &despawn_scoped, OnTransition(StateType));
                }

                fn despawn_scoped(
                    cmd: App.Commands,
                    query: App.Query(.{StateScoped(StateType)}),
                    state: App.Res(State(StateType)),
                ) !void {
                    const current_state: StateType = state.inner.current;
                    var it = query.iterQ(struct { entity: ecs.Entity, scope: *const StateScoped(StateType) });
                    while (it.next()) |en| if (en.scope.state != current_state) try cmd.despawn(en.entity);
                }
            };
        }

        /// # StateScoped Component
        /// despawns entity on state exit
        pub fn StateScoped(comptime S: type) type {
            return struct {
                state: S,
            };
        }

        fn StateObserver(comptime S: type) type {
            return struct {
                last_transition: ?Transition(S) = null,
            };
        }

        /// # System filter `InEnter`
        /// runs only when state is active
        pub fn InState(comptime state: anytype) FilterFunc {
            comptime if (!@typeInfo(@TypeOf(state)).@"enum".is_exhaustive) @compileError("States must be enums");
            return (struct {
                fn isInState(world: *App, _: *ecs.ResourceRegistry) !bool {
                    const s = try world.resource(State(@TypeOf(state)));
                    return s.current == state;
                }
            }).isInState;
        }

        /// # System filter `OnTransition`
        /// runs once on any state transition
        pub fn OnTransition(comptime S: type) FilterFunc {
            comptime if (!@typeInfo(S).@"enum".is_exhaustive) @compileError("States must be enums");
            return (struct {
                fn onEnter(world: *App, locals: *ecs.ResourceRegistry) !bool {
                    const s = try world.resource(State(S));
                    const local = try locals.getOrDefault(world.memtator.world(), StateObserver(S));

                    if (local.last_transition) |last| {
                        if (last.eq(&s.last_transition)) return false;
                    }

                    return true;
                }
            }).onEnter;
        }

        /// # System filter `onEnter`
        /// runs once on enter state
        pub fn OnEnter(comptime state: anytype) FilterFunc {
            comptime if (!@typeInfo(@TypeOf(state)).@"enum".is_exhaustive) @compileError("States must be enums");
            return (struct {
                fn onEnter(world: *App, locals: *ecs.ResourceRegistry) !bool {
                    const s = try world.resource(State(@TypeOf(state)));
                    var local = try locals.getOrDefault(world.memtator.world(), StateObserver(@TypeOf(state)));

                    if (local.last_transition) |last| {
                        if (last.eq(&s.last_transition)) return false;
                    }

                    local.last_transition = s.last_transition;

                    return s.last_transition.to == state;
                }
            }).onEnter;
        }

        /// # System filter `onExit`
        /// runs once on exit state
        pub fn OnExit(comptime state: anytype) FilterFunc {
            comptime if (!@typeInfo(@TypeOf(state)).@"enum".is_exhaustive) @compileError("States must be enums");
            return (struct {
                fn onEnter(world: *App, locals: *ecs.ResourceRegistry) !bool {
                    const s = try world.resource(State(@TypeOf(state)));
                    var local = try locals.getOrDefault(world.memtator.world(), StateObserver(@TypeOf(state)));

                    if (local.last_transition) |last| {
                        if (last.eq(&s.last_transition)) return false;
                    }

                    local.last_transition = s.last_transition;

                    return s.last_transition.from == state;
                }
            }).onEnter;
        }
    };
}
