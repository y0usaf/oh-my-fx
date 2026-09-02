const std = @import("std");
const app_worker_runtime = @import("app_worker_runtime.zig");
const image_attachments = @import("../images/image_attachments.zig");
const tool_result_errors = @import("../tooling/tool_result_errors.zig");
const task_helpers = @import("../tasks/task_helpers.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn startWorkerThread(app: *App) !void {
            app.worker_thread = try std.Thread.spawn(.{}, workerThreadMain, .{app});
        }

        /// Starts one queued prompt on a single-threaded host. Prompt admission
        /// is presented before agent work can suspend on host transport.
        pub fn processNextCooperativePrompt(
            app: *App,
            on_task_completion: *const fn (*anyopaque, task_helpers.TaskCompletion) void,
            event_handlers: app_worker_runtime.WorkerEventHandlers,
            flush_frame: *const fn (*App) anyerror!void,
        ) !void {
            const job = (try app.worker.tryTakeNextPrompt(std.heap.c_allocator)) orelse return;
            defer worker_runtime.freeQueuedPrompt(std.heap.c_allocator, job);

            try app_worker_runtime.Runtime(App).tick(
                app,
                on_task_completion,
                event_handlers,
            );
            try flush_frame(app);

            app.processQueuedPrompt(job) catch |err| {
                if (err != error.RouteRecoveryStopped) {
                    const body = try formatErrorBody(std.heap.c_allocator, "request failed", err);
                    defer std.heap.c_allocator.free(body);
                    try app.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                        .topic = "system",
                        .tone = .@"error",
                        .body = body,
                    } });
                }
            };
            app.worker.finishProcessing();
        }

        pub fn formatToolExecutionError(alloc: std.mem.Allocator, tool_name: []const u8, err: anyerror) ![]u8 {
            const error_detail = detailedErrorSummary(err);
            const details: []const tool_result_errors.Detail = if (error_detail) |detail|
                &[_]tool_result_errors.Detail{
                    .{ .name = "error", .value = .{ .string = @errorName(err) } },
                    .{ .name = "detail", .value = .{ .string = detail } },
                }
            else
                &[_]tool_result_errors.Detail{
                    .{ .name = "error", .value = .{ .string = @errorName(err) } },
                };

            return tool_result_errors.toolExecutionFailureJson(alloc, .{
                .tool_name = tool_name,
                .message = if (error_detail != null) "Tool execution failed while parsing or preparing data" else "Tool execution failed",
                .details = details,
                .suggestion = suggestionForError(err),
            });
        }

        fn detailedErrorSummary(err: anyerror) ?[]const u8 {
            return switch (err) {
                error.StreamInterrupted => "provider response ended before completion",
                error.UnexpectedEndOfInput => "incomplete JSON or internal response while parsing data",
                error.SyntaxError => "invalid JSON syntax while parsing data",
                error.MissingField => "required field missing while parsing data",
                error.InvalidEnumTag => "invalid enum value while parsing data",
                error.UnknownField => "unexpected field while parsing data",
                error.ImageTooLarge => image_attachments.image_too_large_notice,
                error.McpInputTimedOut => tool_result_errors.executionErrorMessage(err),
                else => null,
            };
        }

        fn suggestionForError(err: anyerror) ?[]const u8 {
            return switch (err) {
                error.UnexpectedEndOfInput, error.SyntaxError => "Check that the tool arguments are valid JSON and retry with corrected input.",
                error.MissingField => "Add the required input field named by the tool schema, then retry.",
                error.InvalidEnumTag, error.UnknownField => "Compare the input fields with the tool schema and retry with supported values.",
                error.ImageTooLarge => "Use a smaller image or reduce the image before retrying.",
                error.McpInputTimedOut => tool_result_errors.executionErrorSuggestion(err),
                else => null,
            };
        }

        fn formatErrorBody(alloc: std.mem.Allocator, context: []const u8, err: anyerror) ![]u8 {
            switch (err) {
                error.ConnectionSetupTimedOut => return alloc.dupe(u8, "Connection setup timed out after 30 seconds."),
                error.TlsInitializationFailed => return alloc.dupe(u8, "Connection setup failed: TLS could not be initialized."),
                else => {},
            }
            if (detailedErrorSummary(err)) |detail| {
                return std.fmt.allocPrint(alloc, "{s}: {s} ({s})", .{ context, detail, @errorName(err) });
            }

            return std.fmt.allocPrint(alloc, "{s}: {s}", .{ context, @errorName(err) });
        }

        fn workerThreadMain(app: *App) void {
            workerLoop(app) catch |err| {
                const body = formatErrorBody(std.heap.c_allocator, "worker loop crashed", err) catch return;
                defer std.heap.c_allocator.free(body);
                app.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                    .topic = "system",
                    .tone = .@"error",
                    .body = body,
                } }) catch return;
            };
        }

        fn workerLoop(app: *App) !void {
            while (true) {
                const job = (try app.worker.waitAndTakeNextPrompt(std.heap.c_allocator)) orelse return;

                defer worker_runtime.freeQueuedPrompt(std.heap.c_allocator, job);
                app.processQueuedPrompt(job) catch |err| {
                    if (err != error.RouteRecoveryStopped) {
                        const body = try formatErrorBody(std.heap.c_allocator, "request failed", err);
                        defer std.heap.c_allocator.free(body);
                        try app.worker.pushEvent(std.heap.c_allocator, .{ .error_text = .{
                            .topic = "system",
                            .tone = .@"error",
                            .body = body,
                        } });
                    }
                };

                app.worker.finishProcessing();
            }
        }
    };
}

const DummyApp = struct {
    worker: ?void = null,
    worker_thread: ?std.Thread = null,
};

const TestWorkerApp = struct {
    worker: worker_runtime.WorkerRuntime = .{},
    worker_thread: ?std.Thread = null,
    first_process_error: ?anyerror = null,
    shutdown_after_count: usize = 1,
    processed_count: usize = 0,
    successful_count: usize = 0,
    saw_recovery_prompt: bool = false,

    fn deinit(self: *TestWorkerApp) void {
        if (self.worker_thread) |thread| {
            self.worker.requestShutdown();
            thread.join();
            self.worker_thread = null;
        }
        self.worker.deinit(std.heap.c_allocator);
    }

    fn processQueuedPrompt(self: *TestWorkerApp, job: worker_runtime.QueuedPrompt) !void {
        self.processed_count += 1;
        if (self.processed_count >= self.shutdown_after_count) self.worker.requestShutdown();
        if (self.processed_count == 1) {
            if (self.first_process_error) |err| return err;
        }
        self.successful_count += 1;
        self.saw_recovery_prompt = std.mem.eql(u8, job.prompt, "recovery");
    }
};

fn makeQueuedPrompt(alloc: std.mem.Allocator, text: []const u8) !worker_runtime.QueuedPrompt {
    return .{
        .prompt = try alloc.dupe(u8, text),
        .images = &.{},
        .model = try alloc.dupe(u8, "test-model"),
        .api_key = try alloc.dupe(u8, "test-key"),
        .permission_mode = .ask,
        .history = try alloc.alloc(types.HistoryTurn, 0),
        .grants = try alloc.alloc(types.PermissionGrant, 0),
    };
}

fn queuePrompt(app: *TestWorkerApp, text: []const u8) !void {
    const prompt = try makeQueuedPrompt(std.heap.c_allocator, text);
    errdefer worker_runtime.freeQueuedPrompt(std.heap.c_allocator, prompt);
    try app.worker.enqueuePrompt(std.heap.c_allocator, prompt);
}
