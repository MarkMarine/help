//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const keychain = @import("keychain.zig");

fn debugLog(config: *const Config, comptime fmt: []const u8, args: anytype, src: std.builtin.SourceLocation) void {
    if (config.debug_mode) {
        const stderr = std.io.getStdErr().writer();
        // Extract just the filename from the full path
        const filename = std.fs.path.basename(src.file);
        stderr.print("[DEBUG] {s}:{d} " ++ fmt ++ "\n", .{ filename, src.line } ++ args) catch {};
    }
}

const CommandInfo = struct {
    command: []const u8,
    args: []const []const u8,
    query: ?[]const u8,
};

const LLMProvider = enum {
    openrouter,
    openai,
    anthropic,
    local,
    simulation,

    const Self = @This();

    fn fromString(str: []const u8) ?Self {
        return std.meta.stringToEnum(Self, str);
    }
};

const Config = struct {
    llm_provider: LLMProvider,
    api_key: ?[]const u8,
    api_url: ?[]const u8, // For local or custom endpoints
    model_name: ?[]const u8,
    debug_mode: bool,

    const Self = @This();

    fn fromEnv(allocator: std.mem.Allocator) !Self {
        const provider_str = std.process.getEnvVarOwned(allocator, "LOCALHELP_LLM_PROVIDER") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                // No provider specified, use default but continue with normal config loading
                const provider = LLMProvider.openrouter;
                return Self.loadConfigForProvider(allocator, provider);
            },
            else => return err,
        };
        defer allocator.free(provider_str);

        const provider = LLMProvider.fromString(provider_str) orelse .openrouter;
        return Self.loadConfigForProvider(allocator, provider);
    }

    fn loadConfigForProvider(allocator: std.mem.Allocator, provider: LLMProvider) !Self {
        // First try environment variable, then fall back to keychain
        var api_key: ?[]const u8 = std.process.getEnvVarOwned(allocator, "LOCALHELP_API_KEY") catch null;

        // If no API key in environment, try keychain (macOS only)
        if (api_key == null and @import("builtin").target.os.tag == .macos) {
            api_key = Self.getApiKeyFromKeychain(allocator, provider) catch null;
        }

        const api_url = std.process.getEnvVarOwned(allocator, "LOCALHELP_API_URL") catch null;
        const model_name = std.process.getEnvVarOwned(allocator, "LOCALHELP_MODEL") catch null;

        // Check for debug mode
        const debug_env = std.process.getEnvVarOwned(allocator, "LOCALHELP_DEV") catch null;
        const debug_mode = if (debug_env) |env_val| blk: {
            defer allocator.free(env_val);
            break :blk std.mem.eql(u8, env_val, "true") or std.mem.eql(u8, env_val, "1");
        } else false;

        return Self{
            .llm_provider = provider,
            .api_key = api_key,
            .api_url = api_url,
            .model_name = model_name,
            .debug_mode = debug_mode,
        };
    }

    fn getApiKeyFromKeychain(allocator: std.mem.Allocator, provider: LLMProvider) ![]const u8 {
        const provider_str = @tagName(provider);
        const service_name = keychain.KeychainService.getServiceName(provider_str);
        const current_user = keychain.KeychainService.getCurrentUser(allocator) catch return error.KeychainError;
        defer allocator.free(current_user);

        return keychain.KeychainService.getApiKey(allocator, service_name, current_user) catch |err| switch (err) {
            keychain.KeychainError.KeyNotFound => return error.KeyNotFound,
            else => return error.KeychainError,
        };
    }

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        if (self.api_key) |key| allocator.free(key);
        if (self.api_url) |url| allocator.free(url);
        if (self.model_name) |model| allocator.free(model);
    }
};

// JSON request/response structures for OpenRouter API
const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    // Optional fields that may be present in response
    refusal: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
};

const ChatCompletionRequest = struct {
    model: []const u8,
    messages: []const ChatMessage,
    temperature: f64,
    max_tokens: u32,
};

const MessageChoice = struct {
    message: ChatMessage,
    // Optional fields that we don't need but may be present
    logprobs: ?std.json.Value = null,
    finish_reason: ?[]const u8 = null,
    native_finish_reason: ?[]const u8 = null,
    index: ?u32 = null,
};

const UsageInfo = struct {
    prompt_tokens: ?u32 = null,
    completion_tokens: ?u32 = null,
    total_tokens: ?u32 = null,
};

const ChatCompletionResponse = struct {
    choices: []const MessageChoice,
    // Optional fields that we don't need but may be present in response
    id: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    object: ?[]const u8 = null,
    created: ?u64 = null,
    usage: ?UsageInfo = null,
};

const LLMResponse = struct {
    explanation: []const u8,
    recommended_command: ?[]const u8,
    warnings: ?[]const u8,
    additional_info: ?[]const u8,

    const Self = @This();

    fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.explanation);
        if (self.recommended_command) |cmd| allocator.free(cmd);
        if (self.warnings) |warn| allocator.free(warn);
        if (self.additional_info) |info| allocator.free(info);
    }
};

pub fn processCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Load configuration
    var config = try Config.fromEnv(allocator);
    defer config.deinit(allocator);

    const cmd_info = try parseCommandArgs(allocator, args);
    defer {
        if (cmd_info.query) |q| allocator.free(q);
        allocator.free(cmd_info.args);
    }

    // Get documentation content (man page or help output)
    debugLog(&config, "Attempting to fetch documentation for command: {s}", .{cmd_info.command}, @src());
    const man_content = getManPage(allocator, &config, cmd_info.command, cmd_info.args) catch |err| switch (err) {
        error.ManPageNotFound => {
            debugLog(&config, "No man page or help content found for command: {s}", .{cmd_info.command}, @src());
            if (cmd_info.query) |query| {
                const stdout = std.io.getStdOut().writer();
                try stdout.print("ℹ️  No man page or help content found for '{s}'\n", .{cmd_info.command});
                try processWithLLM(allocator, &config, cmd_info.command, cmd_info.args, null, query);
            } else {
                const stdout = std.io.getStdOut().writer();
                try stdout.print("❌ No documentation found for '{s}' and no query provided.\n", .{cmd_info.command});
                try stdout.print("Usage: help {s} 'your question here'\n", .{cmd_info.command});
            }
            return;
        },
    };
    defer if (man_content) |content| allocator.free(content);

    if (cmd_info.query) |query| {
        try processWithLLM(allocator, &config, cmd_info.command, cmd_info.args, man_content, query);
    } else {
        const stdout = std.io.getStdOut().writer();
        try stdout.print("📖 Documentation for {s}:\n", .{cmd_info.command});
        try stdout.print("════════════════════════\n", .{});
        if (man_content) |content| {
            try stdout.print("{s}\n", .{content});
        }
    }
}

fn parseCommandArgs(allocator: std.mem.Allocator, args: []const []const u8) !CommandInfo {
    if (args.len == 0) return error.NoCommand;

    const command: []const u8 = args[0];
    var cmd_args = std.ArrayList([]const u8).init(allocator);
    defer cmd_args.deinit();

    var query: ?[]const u8 = null;
    var found_query = false;

    // Look for query - check if any arg looks like a sentence rather than a flag/option
    for (args[1..], 1..) |arg, i| {
        // Heuristic: if arg contains spaces or starts with quotes, treat as query
        if (std.mem.indexOf(u8, arg, " ") != null or
            std.mem.startsWith(u8, arg, "'") or
            std.mem.startsWith(u8, arg, "\"") or
            // Or if it's the last arg and contains common query words
            (i == args.len - 1 and (std.mem.indexOf(u8, arg, "I ") != null or
                std.mem.indexOf(u8, arg, "help") != null or
                std.mem.indexOf(u8, arg, "want") != null or
                std.mem.indexOf(u8, arg, "need") != null or
                std.mem.indexOf(u8, arg, "how") != null)))
        {

            // Collect this and all remaining args as query
            var query_builder = std.ArrayList(u8).init(allocator);
            defer query_builder.deinit();

            for (args[i..]) |q_arg| {
                if (query_builder.items.len > 0) {
                    try query_builder.append(' ');
                }

                // Strip quotes if present
                var content = q_arg;
                if ((std.mem.startsWith(u8, content, "'") and std.mem.endsWith(u8, content, "'")) or
                    (std.mem.startsWith(u8, content, "\"") and std.mem.endsWith(u8, content, "\"")))
                {
                    content = content[1 .. content.len - 1];
                }

                try query_builder.appendSlice(content);
            }

            query = try allocator.dupe(u8, query_builder.items);
            found_query = true;
            break;
        } else if (!found_query) {
            try cmd_args.append(arg);
        }
    }

    const final_args = try allocator.dupe([]const u8, cmd_args.items);

    return CommandInfo{
        .command = command,
        .args = final_args,
        .query = query,
    };
}

fn getManPage(allocator: std.mem.Allocator, config: *const Config, command: []const u8, args: []const []const u8) !?[]const u8 {
    // Try to get man page first
    debugLog(config, "Trying to get man page for: {s}", .{command}, @src());
    if (tryGetManPage(allocator, config, command)) |man_content| {
        debugLog(config, "Man page found, length: {d} chars", .{man_content.len}, @src());
        if (config.debug_mode) {
            const preview_len = @min(200, man_content.len);
            debugLog(config, "Man page preview: {s}...", .{man_content[0..preview_len]}, @src());
        }
        return man_content;
    } else |_| {
        debugLog(config, "Man page not found, trying help content", .{}, @src());
        // Fallback to help flags when man page is not available
        if (tryGetHelpContent(allocator, config, command, args)) |help_content| {
            debugLog(config, "Help content found, length: {d} chars", .{help_content.len}, @src());
            if (config.debug_mode) {
                const preview_len = @min(200, help_content.len);
                debugLog(config, "Help content preview: {s}...", .{help_content[0..preview_len]}, @src());
            }
            return help_content;
        } else |_| {
            debugLog(config, "No help content found either", .{}, @src());
            return error.ManPageNotFound;
        }
    }
}

fn tryGetManPage(allocator: std.mem.Allocator, config: *const Config, command: []const u8) ![]const u8 {
    // Use shell to pipe man output through col to clean formatting
    // This gives us: man <command> | col -bx
    var shell_cmd = std.ArrayList(u8).init(allocator);
    defer shell_cmd.deinit();

    try shell_cmd.appendSlice("set -o pipefail; man ");
    try shell_cmd.appendSlice(command);
    try shell_cmd.appendSlice(" | col -bx");

    debugLog(config, "Executing man command: {s}", .{shell_cmd.items}, @src());
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &[_][]const u8{ "sh", "-c", shell_cmd.items },
        .max_output_bytes = 1024 * 1024, // 1MB should be enough for any man page
    }) catch return error.ManPageNotFound;

    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        debugLog(config, "Man command failed with exit code: {d}, stderr: {s}", .{ result.term.Exited, result.stderr }, @src());
        allocator.free(result.stdout);
        return error.ManPageNotFound;
    }

    return result.stdout;
}

fn tryGetHelpContent(allocator: std.mem.Allocator, config: *const Config, command: []const u8, args: []const []const u8) ![]const u8 {
    // Try various help flag combinations
    const help_patterns = [_][]const []const u8{
        // Standard help flags
        &[_][]const u8{ command, "--help" },
        &[_][]const u8{ command, "-h" },
        // Command with subcommand help (like "gt submit --help")
        if (args.len > 0) &[_][]const u8{ command, args[0], "--help" } else &[_][]const u8{ command, "--help" },
        if (args.len > 0) &[_][]const u8{ command, args[0], "-h" } else &[_][]const u8{ command, "-h" },
        // Some tools use "help" as a subcommand
        &[_][]const u8{ command, "help" },
        // Some tools show help with no args or on invalid args
        &[_][]const u8{command},
    };

    for (help_patterns) |pattern| {
        debugLog(config, "Trying help pattern: {s}", .{pattern}, @src());
        if (tryExecuteHelpCommand(allocator, config, pattern)) |help_content| {
            return help_content;
        } else |_| {
            // Continue to next pattern
            continue;
        }
    }

    return error.ManPageNotFound;
}

fn tryExecuteHelpCommand(allocator: std.mem.Allocator, config: *const Config, argv: []const []const u8) ![]const u8 {
    debugLog(config, "Executing help command: {s}", .{argv}, @src());
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 1024 * 1024, // 1MB limit
    }) catch return error.HelpCommandFailed;

    defer allocator.free(result.stderr);

    // Accept both successful execution and some common "help" exit codes
    // Many help commands exit with code 0, but some exit with 1 or 2
    const is_valid_help = result.term.Exited == 0 or
        result.term.Exited == 1 or
        result.term.Exited == 2;

    if (!is_valid_help) {
        debugLog(config, "Help command failed with exit code: {d}, stderr: {s}", .{ result.term.Exited, result.stderr }, @src());
        allocator.free(result.stdout);
        return error.HelpCommandFailed;
    }

    // Check if output looks like help content (contains common help indicators)
    const content = result.stdout;
    const looks_like_help = std.mem.indexOf(u8, content, "Usage:") != null or
        std.mem.indexOf(u8, content, "usage:") != null or
        std.mem.indexOf(u8, content, "USAGE:") != null or
        std.mem.indexOf(u8, content, "Options:") != null or
        std.mem.indexOf(u8, content, "options:") != null or
        std.mem.indexOf(u8, content, "Commands:") != null or
        std.mem.indexOf(u8, content, "commands:") != null or
        std.mem.indexOf(u8, content, "--help") != null or
        std.mem.indexOf(u8, content, "Examples:") != null or
        std.mem.indexOf(u8, content, "Description:") != null;

    if (!looks_like_help or content.len < 10) {
        debugLog(config, "Output doesn't look like help content, length: {d}, looks_like_help: {}", .{ content.len, looks_like_help }, @src());
        allocator.free(result.stdout);
        return error.HelpCommandFailed;
    }

    debugLog(config, "Successfully got help content, length: {d}", .{content.len}, @src());

    return content;
}

fn processWithLLM(allocator: std.mem.Allocator, config: *const Config, command: []const u8, args: []const []const u8, man_content: ?[]const u8, query: []const u8) !void {
    // Build the full command string
    var full_command = std.ArrayList(u8).init(allocator);
    defer full_command.deinit();

    try full_command.appendSlice(command);
    for (args) |arg| {
        try full_command.append(' ');
        try full_command.appendSlice(arg);
    }

    // Create structured prompt for LLM
    var prompt = std.ArrayList(u8).init(allocator);
    defer prompt.deinit();

    try prompt.appendSlice("You are a command line expert. Help the user with this command context.\n\n");
    try prompt.appendSlice("COMMAND CONTEXT: ");
    try prompt.appendSlice(full_command.items);
    try prompt.appendSlice("\nUSER QUERY: ");
    try prompt.appendSlice(query);

    if (man_content) |content| {
        try prompt.appendSlice("\n\nMAN PAGE CONTENT:\n");
        // Limit man page content to avoid overwhelming the LLM
        const max_man_content = 2000;
        const content_preview = if (content.len > max_man_content) content[0..max_man_content] else content;
        try prompt.appendSlice(content_preview);
        if (content.len > max_man_content) {
            try prompt.appendSlice("\n... (truncated)");
        }
    }

    try prompt.appendSlice("\n\nPlease respond with structured output in this exact format:\n\n");
    try prompt.appendSlice("EXPLANATION: [Brief explanation of what the user wants to achieve]\n");
    try prompt.appendSlice("COMMAND: [Exact command to run, or NONE if no specific command recommended]\n");
    try prompt.appendSlice("WARNINGS: [Any important warnings or caveats, or NONE]\n");
    try prompt.appendSlice("INFO: [Additional helpful information, or NONE]\n");

    debugLog(config, "Sending LLM request with provider: {s}", .{@tagName(config.llm_provider)}, @src());
    if (config.debug_mode) {
        const preview_len = @min(500, prompt.items.len);
        debugLog(config, "LLM prompt preview: {s}...", .{prompt.items[0..preview_len]}, @src());
    }

    // Get LLM response based on configured provider
    var llm_response = try getLLMResponse(allocator, config, prompt.items);
    defer llm_response.deinit(allocator);

    // Display structured response
    try displayLLMResponse(&llm_response);

    // Execute command if recommended
    if (llm_response.recommended_command) |cmd| {
        if (!std.mem.eql(u8, cmd, "NONE")) {
            try askAndExecute(allocator, cmd);
        }
    }
}

fn getLLMResponse(allocator: std.mem.Allocator, config: *const Config, prompt: []const u8) !LLMResponse {
    debugLog(config, "Getting LLM response using provider: {s}", .{@tagName(config.llm_provider)}, @src());

    const response = switch (config.llm_provider) {
        .openrouter => try callOpenRouter(allocator, config, prompt),
        .openai => try callOpenAI(allocator, config, prompt),
        .anthropic => try callAnthropic(allocator, config, prompt),
        .local => try callLocalLLM(allocator, config, prompt),
        .simulation => try simulateLLMResponse(allocator, prompt),
    };

    debugLog(config, "LLM response received successfully", .{}, @src());
    if (config.debug_mode) {
        const preview_len = @min(300, response.explanation.len);
        debugLog(config, "LLM response explanation preview: {s}...", .{response.explanation[0..preview_len]}, @src());
        if (response.recommended_command) |cmd| {
            debugLog(config, "LLM recommended command: {s}", .{cmd}, @src());
        }
    }

    return response;
}

fn callOpenRouter(allocator: std.mem.Allocator, config: *const Config, prompt: []const u8) !LLMResponse {
    if (config.api_key == null) {
        return LLMResponse{
            .explanation = try allocator.dupe(u8, "OpenRouter provider selected but no API key configured."),
            .recommended_command = null,
            .warnings = try allocator.dupe(u8, "Set LOCALHELP_API_KEY environment variable with your OpenRouter API key."),
            .additional_info = try allocator.dupe(u8, "Get your key at https://openrouter.ai/keys. Example: export LOCALHELP_API_KEY=sk-or-..."),
        };
    }

    // Use default model if not specified
    const model = config.model_name orelse "anthropic/claude-3.7-sonnet";

    debugLog(config, "Making OpenRouter request with model: {s}", .{model}, @src());

    // Make HTTP request to OpenRouter
    const response_text = try makeOpenRouterRequest(allocator, config, model, prompt);
    defer allocator.free(response_text);

    debugLog(config, "OpenRouter response received, length: {d}", .{response_text.len}, @src());
    if (config.debug_mode) {
        const preview_len = @min(200, response_text.len);
        debugLog(config, "OpenRouter raw response preview: {s}...", .{response_text[0..preview_len]}, @src());
    }

    // Parse the structured response
    return try parseStructuredResponse(allocator, response_text);
}

fn makeOpenRouterRequest(allocator: std.mem.Allocator, config: *const Config, model: []const u8, prompt: []const u8) ![]const u8 {
    // Use Zig's HTTP client (updated for current master)
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Build JSON payload using std.json.stringify
    const request = ChatCompletionRequest{
        .model = model,
        .messages = &[_]ChatMessage{.{
            .role = "user",
            .content = prompt,
        }},
        .temperature = 0.7,
        .max_tokens = 1000,
    };

    var json_payload = std.ArrayList(u8).init(allocator);
    defer json_payload.deinit();
    
    try std.json.stringify(request, .{}, json_payload.writer());

    debugLog(config, "OpenRouter JSON payload size: {d} bytes", .{json_payload.items.len}, @src());
    if (config.debug_mode) {
        const preview_len = @min(300, json_payload.items.len);
        debugLog(config, "OpenRouter JSON payload preview: {s}...", .{json_payload.items[0..preview_len]}, @src());
    }

    // Create URI
    const uri = try std.Uri.parse("https://openrouter.ai/api/v1/chat/completions");

    // Create authorization header
    const auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{config.api_key.?});
    defer allocator.free(auth_header);

    // Allocate server header buffer
    const server_header_buffer = try allocator.alloc(u8, 16384);
    defer allocator.free(server_header_buffer);

    // Make request with required fields
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = server_header_buffer,
        .headers = .{
            .authorization = .{ .override = auth_header },
            .content_type = .{ .override = "application/json" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = json_payload.items.len };

    debugLog(config, "Sending OpenRouter HTTP request to: {s}", .{"openrouter.ai"}, @src());

    try req.send();
    try req.writeAll(json_payload.items);
    try req.finish();
    try req.wait();

    // Check status
    debugLog(config, "OpenRouter HTTP response status: {}", .{req.response.status}, @src());
    if (req.response.status != .ok) {
        debugLog(config, "OpenRouter API request failed with status: {}", .{req.response.status}, @src());
        return error.APIRequestFailed;
    }

    // Read response
    var response_body = std.ArrayList(u8).init(allocator);
    defer response_body.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const bytes_read = try req.readAll(buf[0..]);
        if (bytes_read == 0) break;
        try response_body.appendSlice(buf[0..bytes_read]);
    }

    debugLog(config, "OpenRouter response body size: {d} bytes", .{response_body.items.len}, @src());
    if (config.debug_mode) {
        const preview_len = @min(500, response_body.items.len);
        debugLog(config, "OpenRouter response body preview: {s}...", .{response_body.items[0..preview_len]}, @src());
    }

    // Parse JSON to extract the message content
    return try parseOpenRouterResponse(allocator, response_body.items);
}

fn parseOpenRouterResponse(allocator: std.mem.Allocator, json_response: []const u8) ![]const u8 {
    // Parse JSON response to extract the assistant's message content
    // OpenRouter returns: {"choices": [{"message": {"content": "response text"}}]}
    
    const parsed = std.json.parseFromSlice(ChatCompletionResponse, allocator, json_response, .{}) catch |err| {
        std.debug.print("Failed to parse OpenRouter JSON response: {}\n", .{err});
        std.debug.print("Response was: {s}\n", .{json_response});
        return error.InvalidJSONResponse;
    };
    defer parsed.deinit();
    
    if (parsed.value.choices.len == 0) {
        std.debug.print("No choices in OpenRouter response\n", .{});
        return error.InvalidJSONResponse;
    }
    
    const content = parsed.value.choices[0].message.content;
    return try allocator.dupe(u8, content);
}

fn parseStructuredResponse(allocator: std.mem.Allocator, response: []const u8) !LLMResponse {
    var explanation: ?[]const u8 = null;
    var command: ?[]const u8 = null;
    var warnings: ?[]const u8 = null;
    var info: ?[]const u8 = null;

    var lines = std.mem.splitScalar(u8, response, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "EXPLANATION: ")) {
            const content = trimmed[13..]; // "EXPLANATION: ".len
            explanation = try allocator.dupe(u8, content);
        } else if (std.mem.startsWith(u8, trimmed, "COMMAND: ")) {
            const content = trimmed[9..]; // "COMMAND: ".len
            if (!std.mem.eql(u8, content, "NONE")) {
                command = try allocator.dupe(u8, content);
            }
        } else if (std.mem.startsWith(u8, trimmed, "WARNINGS: ")) {
            const content = trimmed[10..]; // "WARNINGS: ".len
            if (!std.mem.eql(u8, content, "NONE")) {
                warnings = try allocator.dupe(u8, content);
            }
        } else if (std.mem.startsWith(u8, trimmed, "INFO: ")) {
            const content = trimmed[6..]; // "INFO: ".len
            if (!std.mem.eql(u8, content, "NONE")) {
                info = try allocator.dupe(u8, content);
            }
        }
    }

    return LLMResponse{
        .explanation = explanation orelse try allocator.dupe(u8, "Unable to parse explanation from response."),
        .recommended_command = command,
        .warnings = warnings,
        .additional_info = info,
    };
}

// TODO: Implement actual OpenAI API call
fn callOpenAI(allocator: std.mem.Allocator, config: *const Config, prompt: []const u8) !LLMResponse {
    if (config.api_key == null) {
        return LLMResponse{
            .explanation = try allocator.dupe(u8, "OpenAI provider selected but no API key configured."),
            .recommended_command = null,
            .warnings = try allocator.dupe(u8, "Set LOCALHELP_API_KEY environment variable with your OpenAI API key."),
            .additional_info = try allocator.dupe(u8, "Example: export LOCALHELP_API_KEY=sk-..."),
        };
    }

    _ = prompt;

    return LLMResponse{
        .explanation = try allocator.dupe(u8, "OpenAI integration placeholder"),
        .recommended_command = null,
        .warnings = try allocator.dupe(u8, "OpenAI API integration not yet implemented."),
        .additional_info = try allocator.dupe(u8, "Coming soon! For now, use simulation mode."),
    };
}

// TODO: Implement actual OpenAI API call
fn callAnthropic(allocator: std.mem.Allocator, config: *const Config, prompt: []const u8) !LLMResponse {
    if (config.api_key == null) {
        return LLMResponse{
            .explanation = try allocator.dupe(u8, "Anthropic provider selected but no API key configured."),
            .recommended_command = null,
            .warnings = try allocator.dupe(u8, "Set LOCALHELP_API_KEY environment variable with your Anthropic API key."),
            .additional_info = try allocator.dupe(u8, "Example: export LOCALHELP_API_KEY=sk-ant-..."),
        };
    }

    // TODO: Implement actual Anthropic API call
    _ = prompt;

    return LLMResponse{
        .explanation = try allocator.dupe(u8, "Anthropic integration placeholder"),
        .recommended_command = null,
        .warnings = try allocator.dupe(u8, "Anthropic API integration not yet implemented."),
        .additional_info = try allocator.dupe(u8, "Coming soon! For now, use simulation mode."),
    };
}

// TODO: Implement actual OpenAI API call
fn callLocalLLM(allocator: std.mem.Allocator, config: *const Config, prompt: []const u8) !LLMResponse {
    if (config.api_url == null) {
        return LLMResponse{
            .explanation = try allocator.dupe(u8, "Local LLM provider selected but no API URL configured."),
            .recommended_command = null,
            .warnings = try allocator.dupe(u8, "Set LOCALHELP_API_URL environment variable with your local LLM endpoint."),
            .additional_info = try allocator.dupe(u8, "Example: export LOCALHELP_API_URL=http://localhost:11434"),
        };
    }

    // TODO: Implement local LLM API call (e.g., Ollama)
    _ = prompt;

    return LLMResponse{
        .explanation = try allocator.dupe(u8, "Local LLM integration placeholder"),
        .recommended_command = null,
        .warnings = try allocator.dupe(u8, "Local LLM API integration not yet implemented."),
        .additional_info = try allocator.dupe(u8, "Coming soon! For now, use simulation mode."),
    };
}

fn simulateLLMResponse(allocator: std.mem.Allocator, prompt: []const u8) !LLMResponse {
    // Extract basic info from prompt for simulation
    const has_man_page = std.mem.indexOf(u8, prompt, "MAN PAGE CONTENT:") != null;

    // Simple pattern matching for common scenarios
    if (std.mem.indexOf(u8, prompt, "git") != null and std.mem.indexOf(u8, prompt, "reset") != null and std.mem.indexOf(u8, prompt, "unstage") != null) {
        const info_msg = if (has_man_page)
            "After running this command, your changes will still be present in your working directory but will no longer be staged for commit. You can re-stage them later with 'git add'. (Analysis based on git man page)"
        else
            "After running this command, your changes will still be present in your working directory but will no longer be staged for commit. You can re-stage them later with 'git add'.";

        return LLMResponse{
            .explanation = try allocator.dupe(u8, "You want to unstage changes that are currently in the git index (staging area) but keep them as modified files in your working directory."),
            .recommended_command = try allocator.dupe(u8, "git reset HEAD"),
            .warnings = try allocator.dupe(u8, "This will unstage ALL staged changes. To unstage specific files, use 'git reset HEAD <filename>'."),
            .additional_info = try allocator.dupe(u8, info_msg),
        };
    } else if (std.mem.indexOf(u8, prompt, "docker") != null and std.mem.indexOf(u8, prompt, "ps") != null and std.mem.indexOf(u8, prompt, "running") != null) {
        const info_msg = if (has_man_page)
            "By default, 'docker ps' only shows running containers. To see all containers including stopped ones, use 'docker ps -a'. (Analysis based on docker man page)"
        else
            "By default, 'docker ps' only shows running containers. To see all containers including stopped ones, use 'docker ps -a'.";

        return LLMResponse{
            .explanation = try allocator.dupe(u8, "You want to see only currently running Docker containers, not stopped ones."),
            .recommended_command = try allocator.dupe(u8, "docker ps"),
            .warnings = null,
            .additional_info = try allocator.dupe(u8, info_msg),
        };
    } else {
        const status_msg = if (has_man_page)
            "This is a simulated response with man page context. For real AI assistance, configure an API key."
        else
            "This is a simulated response without man page context. For real AI assistance, configure an API key.";

        return LLMResponse{
            .explanation = try allocator.dupe(u8, "This is a simulated LLM response for testing purposes."),
            .recommended_command = null,
            .warnings = try allocator.dupe(u8, status_msg),
            .additional_info = try allocator.dupe(u8, "Set LOCALHELP_LLM_PROVIDER and LOCALHELP_API_KEY environment variables."),
        };
    }
}

fn displayLLMResponse(response: *const LLMResponse) !void {
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n🤖 AI Assistant Response:\n", .{});
    try stdout.print("═══════════════════════════\n", .{});

    try stdout.print("\n📋 EXPLANATION:\n{s}\n", .{response.explanation});

    if (response.recommended_command) |cmd| {
        if (!std.mem.eql(u8, cmd, "NONE")) {
            try stdout.print("\n💻 RECOMMENDED COMMAND:\n{s}\n", .{cmd});
        }
    }

    if (response.warnings) |warnings| {
        if (!std.mem.eql(u8, warnings, "NONE")) {
            try stdout.print("\n⚠️  WARNINGS:\n{s}\n", .{warnings});
        }
    }

    if (response.additional_info) |info| {
        if (!std.mem.eql(u8, info, "NONE")) {
            try stdout.print("\n💡 ADDITIONAL INFO:\n{s}\n", .{info});
        }
    }

    try stdout.print("\n═══════════════════════════\n", .{});
}

fn askAndExecute(allocator: std.mem.Allocator, suggested_command: []const u8) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    try stdout.print("\n🚀 Execute Command?\n", .{});
    try stdout.print("Command: {s}\n", .{suggested_command});
    try stdout.print("Run this command? (y/N): ", .{});

    // Read user input
    var buffer: [100]u8 = undefined;
    if (try stdin.readUntilDelimiterOrEof(buffer[0..], '\n')) |input| {
        const trimmed = std.mem.trim(u8, input, " \t\r\n");

        if (std.mem.eql(u8, trimmed, "y") or std.mem.eql(u8, trimmed, "Y") or std.mem.eql(u8, trimmed, "yes")) {
            try stdout.print("\n⚡ Executing: {s}\n", .{suggested_command});
            try stdout.print("─────────────────────────\n", .{});

            // Parse the command into argv
            var command_parts = std.mem.splitScalar(u8, suggested_command, ' ');
            var argv = std.ArrayList([]const u8).init(allocator);
            defer argv.deinit();

            while (command_parts.next()) |part| {
                if (part.len > 0) {
                    try argv.append(part);
                }
            }

            if (argv.items.len == 0) {
                try stdout.print("❌ Error: No command to execute\n", .{});
                return;
            }

            // Execute the command
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = argv.items,
            }) catch |err| {
                try stdout.print("❌ Error executing command: {}\n", .{err});
                return;
            };

            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            if (result.stdout.len > 0) {
                try stdout.print("\n📤 Output:\n{s}", .{result.stdout});
            }

            if (result.stderr.len > 0) {
                try stdout.print("\n📤 Error output:\n{s}", .{result.stderr});
            }

            if (result.term.Exited == 0) {
                try stdout.print("\n✅ Command executed successfully!\n", .{});
            } else {
                try stdout.print("\n❌ Command failed with exit code: {}\n", .{result.term.Exited});
            }
        } else {
            try stdout.print("\n🚫 Command not executed.\n", .{});
        }
    }
}

test "LLMProvider fromString" {
    // Test valid providers
    try std.testing.expectEqual(LLMProvider.openrouter, LLMProvider.fromString("openrouter").?);
    try std.testing.expectEqual(LLMProvider.openai, LLMProvider.fromString("openai").?);
    try std.testing.expectEqual(LLMProvider.anthropic, LLMProvider.fromString("anthropic").?);
    try std.testing.expectEqual(LLMProvider.local, LLMProvider.fromString("local").?);
    try std.testing.expectEqual(LLMProvider.simulation, LLMProvider.fromString("simulation").?);

    // Test invalid providers
    try std.testing.expectEqual(@as(?LLMProvider, null), LLMProvider.fromString("invalid"));
    try std.testing.expectEqual(@as(?LLMProvider, null), LLMProvider.fromString(""));
    try std.testing.expectEqual(@as(?LLMProvider, null), LLMProvider.fromString("OpenRouter")); // case sensitive
}

test "command parsing" {
    const allocator = std.testing.allocator;

    // Test basic command
    const args1 = [_][]const u8{ "git", "reset", "'help me unstage'" };
    const cmd_info = try parseCommandArgs(allocator, &args1);
    defer allocator.free(cmd_info.args);
    defer if (cmd_info.query) |q| allocator.free(q);

    try std.testing.expectEqualStrings("git", cmd_info.command);
    try std.testing.expectEqual(@as(usize, 1), cmd_info.args.len);
    try std.testing.expectEqualStrings("reset", cmd_info.args[0]);
    try std.testing.expect(cmd_info.query != null);
    try std.testing.expectEqualStrings("help me unstage", cmd_info.query.?);
}
