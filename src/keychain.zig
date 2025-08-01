const std = @import("std");
const c = @cImport({
    @cInclude("Security/Security.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

pub const KeychainError = error{
    KeyNotFound,
    InvalidKeychain,
    AccessDenied,
    InvalidParameters,
    UnknownError,
    OutOfMemory,
};

pub const KeychainService = struct {
    const Self = @This();

    /// Fetch an API key from the macOS keychain
    /// service: The service name (e.g., "localhelp-openrouter", "localhelp-openai")
    /// account: The account name (typically the user's identifier or email)
    /// Returns an allocated string that must be freed by the caller
    pub fn getApiKey(allocator: std.mem.Allocator, service: []const u8, account: []const u8) KeychainError![]const u8 {
        var password_data: ?*anyopaque = null;
        var password_length: u32 = 0;

        // Query the keychain
        const status = c.SecKeychainFindGenericPassword(
            null, // default keychain
            @intCast(service.len),
            service.ptr,
            @intCast(account.len),
            account.ptr,
            &password_length,
            &password_data,
            null // item reference (not needed)
        );

        switch (status) {
            c.errSecSuccess => {},
            c.errSecItemNotFound => return KeychainError.KeyNotFound,
            c.errSecAuthFailed => return KeychainError.AccessDenied,
            c.errSecParam => return KeychainError.InvalidParameters,
            else => return KeychainError.UnknownError,
        }

        if (password_data == null or password_length == 0) {
            return KeychainError.KeyNotFound;
        }

        // Copy the password data to an allocated string
        const password_bytes = @as([*]const u8, @ptrCast(password_data.?))[0..password_length];
        const result = allocator.dupe(u8, password_bytes) catch return KeychainError.OutOfMemory;

        // Free the keychain data
        _ = c.SecKeychainItemFreeContent(null, password_data);

        return result;
    }

    /// Store an API key in the macOS keychain
    /// service: The service name (e.g., "localhelp-openrouter", "localhelp-openai")
    /// account: The account name (typically the user's identifier or email)
    /// password: The API key to store
    pub fn setApiKey(service: []const u8, account: []const u8, password: []const u8) KeychainError!void {
        // Try to find existing item first
        var existing_item: c.SecKeychainItemRef = undefined;
        const find_status = c.SecKeychainFindGenericPassword(
            null, // default keychain
            @intCast(service.len),
            service.ptr,
            @intCast(account.len),
            account.ptr,
            null,
            null,
            &existing_item
        );

        if (find_status == c.errSecSuccess) {
            // Update existing item
            const update_status = c.SecKeychainItemModifyContent(
                existing_item,
                null,
                @intCast(password.len),
                password.ptr
            );
            c.CFRelease(existing_item);

            switch (update_status) {
                c.errSecSuccess => return,
                c.errSecAuthFailed => return KeychainError.AccessDenied,
                c.errSecParam => return KeychainError.InvalidParameters,
                else => return KeychainError.UnknownError,
            }
        } else {
            // Create new item
            const add_status = c.SecKeychainAddGenericPassword(
                null, // default keychain
                @intCast(service.len),
                service.ptr,
                @intCast(account.len),
                account.ptr,
                @intCast(password.len),
                password.ptr,
                null // item reference (not needed)
            );

            switch (add_status) {
                c.errSecSuccess => return,
                c.errSecAuthFailed => return KeychainError.AccessDenied,
                c.errSecParam => return KeychainError.InvalidParameters,
                c.errSecDuplicateItem => return, // Item already exists, that's fine
                else => return KeychainError.UnknownError,
            }
        }
    }

    /// Delete an API key from the macOS keychain
    /// service: The service name (e.g., "localhelp-openrouter", "localhelp-openai")
    /// account: The account name (typically the user's identifier or email)
    pub fn deleteApiKey(service: []const u8, account: []const u8) KeychainError!void {
        var item_ref: c.SecKeychainItemRef = undefined;

        const find_status = c.SecKeychainFindGenericPassword(
            null, // default keychain
            @intCast(service.len),
            service.ptr,
            @intCast(account.len),
            account.ptr,
            null,
            null,
            &item_ref
        );

        switch (find_status) {
            c.errSecSuccess => {},
            c.errSecItemNotFound => return KeychainError.KeyNotFound,
            c.errSecAuthFailed => return KeychainError.AccessDenied,
            else => return KeychainError.UnknownError,
        }

        const delete_status = c.SecKeychainItemDelete(item_ref);
        c.CFRelease(item_ref);

        switch (delete_status) {
            c.errSecSuccess => return,
            c.errSecAuthFailed => return KeychainError.AccessDenied,
            else => return KeychainError.UnknownError,
        }
    }

    /// Get a service name for the given LLM provider
    pub fn getServiceName(provider: []const u8) []const u8 {
        const service_map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "openrouter", "localhelp-openrouter" },
            .{ "openai", "localhelp-openai" },
            .{ "anthropic", "localhelp-anthropic" },
        });
        
        return service_map.get(provider) orelse "localhelp-unknown";
    }

    /// Get the current user's account name for keychain storage
    pub fn getCurrentUser(allocator: std.mem.Allocator) ![]const u8 {
        const user_env = std.process.getEnvVarOwned(allocator, "USER") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => {
                // Fallback to whoami command
                const result = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &[_][]const u8{ "whoami" },
                    .max_output_bytes = 256,
                }) catch return error.OutOfMemory;

                defer allocator.free(result.stderr);

                if (result.term.Exited != 0) {
                    allocator.free(result.stdout);
                    return error.OutOfMemory;
                }

                // Trim whitespace from whoami output
                const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
                const user = try allocator.dupe(u8, trimmed);
                allocator.free(result.stdout);
                return user;
            },
            else => return err,
        };

        return user_env;
    }
};

test "keychain service name generation" {
    const testing = std.testing;

    // Test known providers
    try testing.expectEqualStrings("localhelp-openrouter", KeychainService.getServiceName("openrouter"));
    try testing.expectEqualStrings("localhelp-openai", KeychainService.getServiceName("openai"));
    try testing.expectEqualStrings("localhelp-anthropic", KeychainService.getServiceName("anthropic"));
    
    // Test unknown/edge cases
    try testing.expectEqualStrings("localhelp-unknown", KeychainService.getServiceName("unknown"));
    try testing.expectEqualStrings("localhelp-unknown", KeychainService.getServiceName(""));
    try testing.expectEqualStrings("localhelp-unknown", KeychainService.getServiceName("OPENROUTER")); // case sensitive
}
