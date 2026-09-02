pub const ModelPromptOverlayFn = *const fn (model: []const u8) ?[]const u8;

pub const Policy = struct {
    system_prompt: []const u8,
    model_prompt_overlay_fn: ?ModelPromptOverlayFn = null,

    pub fn modelPromptOverlay(self: Policy, model: []const u8) ?[]const u8 {
        const overlay_fn = self.model_prompt_overlay_fn orelse return null;
        return overlay_fn(model);
    }
};

