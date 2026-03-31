pub const ecs = @import("ecs.zig");
pub const ev = @import("events.zig");
pub const st = @import("state.zig");
pub const std = @import("std");

pub const MB: usize = 1024 * 1000;
pub const GB: usize = MB * 1000;

/// ECS configuration
pub const AppDesc = struct {
    /// how many cores ? (set it to 1 for web)
    thread_count: comptime_int = 8,
    /// frame arena max size
    max_frame_mem: usize = 64 * MB,
    /// defines max components and resources bit sets u6 = 64 Components max
    FlagInt: type = u6,
};

/// Knödel ECS
pub fn Knoedel(cfg: AppDesc) type {
    return struct {
        pub const MB = ecs.MB;
        pub const GB = ecs.GB;
        pub const App = ecs.App(cfg);
        pub const Entity = ecs.Entity;
        pub const Has = ecs.Has;
        pub const Meta = ecs.ArchType(cfg.FlagInt).Meta;
        pub const Res = App.Res;
        pub const ResMut = App.ResMut;
        pub const Local = ecs.Local;
        pub const Query = App.Query;
        pub const Filter = ecs.Filter;
        pub const QueryF = App.QueryF;
        pub const Alloc = App.Alloc;
        pub const Jobs = App.Jobs;
        pub const And = App.And;
        pub const Or = App.Or;
        pub const Chain = ecs.Chain;
        pub const Commands = App.Commands;
        pub const CommandFn = App.CommandFn;
        pub const CompFlag = ecs.HeapFlagSet(cfg.FlagInt).Flag;
        pub const CompInfo = ecs.HeapFlagSet(cfg.FlagInt).Info;
        pub const hashType = ecs.hashType;
        pub const Children = ecs.Children;
        pub const Parent = ecs.Parent;
        pub const ResouceRegistry = ecs.ResourceRegistry(cfg.FlagInt);
        pub const ConditionFn = App.SystemRegistry.ConditionFn;
        pub const SystemFn = App.SystemRegistry.SystemFn;
        pub const Error = ecs.EcsError;
        pub const Access = ecs.Access(cfg.FlagInt);
        pub const World = ecs.WorldAccess(cfg);

        // Event Extension
        const e = ev.EventExtension(cfg);
        pub const EventPlugin = e.EventStorePlugin;
        pub const EventStore = ev.EventStore;
        pub const EventReader = e.EventReader;
        pub const EventWriter = e.EventWriter;

        // State Extension
        const s = st.StateExtension(cfg);
        pub const State = s.State;
        pub const StateScoped = s.StateScoped;
        pub const StatePlugin = s.StatePlugin;
        pub const Transition = s.Transition;
        pub const InState = s.InState;
        pub const OnEnter = s.OnEnter;
        pub const OnExit = s.OnExit;
        pub const OnTransition = s.OnTransition;
    };
}
