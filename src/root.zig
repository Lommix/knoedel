pub const ecs = @import("ecs.zig");
pub const ev = @import("events.zig");
pub const st = @import("state.zig");

/// Knödel ECS
pub fn Knoedel(cfg: ecs.AppDesc) type {
    return struct {
        pub const MB = ecs.MB;
        pub const GB = ecs.GB;
        pub const App = ecs.App(cfg);
        pub const Entity = ecs.Entity;
        pub const Mut = ecs.Mut;
        pub const Has = ecs.Has;
        pub const Res = App.Res;
        pub const ResMut = App.ResMut;
        pub const Local = ecs.Local;
        pub const Query = App.Query;
        pub const QueryS = App.QueryS;
        pub const QuerySFiltered = App.QuerySFiltered;
        pub const QueryFiltered = App.QueryFiltered;
        pub const Alloc = App.Alloc;
        pub const Jobs = App.Jobs;
        pub const And = App.And;
        pub const Or = App.Or;
        pub const Added = ecs.Added;
        pub const Changed = ecs.Changed;
        pub const With = ecs.With;
        pub const Chain = ecs.Chain;
        pub const WithOut = ecs.WithOut;
        pub const Commands = App.Commands;
        pub const CommandFn = App.CommandFn;
        pub const Children = ecs.Children;
        pub const Parent = ecs.Parent;
        pub const ResouceRegistry = ecs.ResourceRegistry(cfg.FlagInt);
        pub const ConditionFn = App.SystemRegistry.ConditionFn;
        pub const SystemFn = App.SystemRegistry.SystemFn;
        pub const Error = ecs.EcsError;
        pub const Access = ecs.Access(cfg.FlagInt);
        pub const World = ecs.WorldAccess(cfg);
        // pub const ResFlag = ecs.ResFlag;
        // pub const CompFlag = ecs.CompFlag;

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
