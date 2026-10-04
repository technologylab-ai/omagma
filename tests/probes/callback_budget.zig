const std = @import("std");
const engine = @import("engine");
pub fn main() !void {
    const c: engine.Config = .{ .connections = 2, .workers = 0, .shards = 1, .max_body = 0, .max_header = 8192, .output_bytes = 1024, .callback_output_reserve = 1024, .response_batch_limit = 1, .max_headers = 32, .port = 0, .memory_budget_bytes = 1024 * 1024 };
    try c.validate();
    std.debug.print("callback engine requested heap={d}, workers={d}, app stacks={d}\n", .{ try c.heapBytes(), c.workers, c.worker_stack_bytes * c.workers });
}
