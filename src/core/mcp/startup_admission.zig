//! Pure admission policy for selecting which configured MCP servers connect in
//! each product startup phase.

const mcp_contract = @import("mcp_contract.zig");

pub const Phase = enum {
    all,
    ask_startup,
    ask_deferred,
    acp_startup,
};

pub const Decision = enum {
    connect,
    deferred,
    disabled,
};

pub fn decide(
    enabled: bool,
    required: bool,
    workspace_admission: ?mcp_contract.WorkspaceAdmission,
    phase: Phase,
) Decision {
    if (!enabled) return .disabled;
    if (workspace_admission) |admission| {
        return switch (admission) {
            .rejected => .disabled,
            .pending => .disabled,
            .approved => switch (phase) {
                .all, .ask_startup, .acp_startup => .connect,
                .ask_deferred => .deferred,
            },
        };
    }
    return switch (phase) {
        .all => .connect,
        .ask_startup => if (required) .connect else .deferred,
        .ask_deferred => if (required) .deferred else .connect,
        .acp_startup => .connect,
    };
}
