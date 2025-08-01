# Help - Intelligent Command Line Assistant

Help is an AI-powered command line tool that helps you understand and execute command line tools. It combines man page documentation with AI intelligence to provide contextual assistance and safe command execution.

## Features

- 🤖 **AI-powered assistance** using Claude 3.5 Sonnet, GPT-4, or other models via OpenRouter
- 📖 **Man page integration** - automatically fetches and includes command documentation
- 🔍 **Smart query parsing** - understands natural language questions about commands
- 🛡️ **Safe execution** - always asks for confirmation before running suggested commands
- 📋 **Structured responses** - clear explanations, warnings, and additional information
- ⚡ **Pure Zig implementation** - no external dependencies except for optional API providers

## Quick Start

### Installation

1. **Clone and build:**
   ```bash
   git clone <repository-url>
   cd Help
   zig build
   ```

2. **Install locally:**
   ```bash
   zig build install
   # Binary will be created at zig-out/bin/help
   ```

3. **Make available system-wide (choose one method):**

   **Option A: Symlink to /usr/local/bin (recommended):**
   ```bash
   sudo ln -sf "$(pwd)/zig-out/bin/localhelp" /usr/local/bin/help
   # Now you can use 'help' from anywhere
   ```

   **Option B: Symlink to ~/.local/bin (user-only):**
   ```bash
   mkdir -p ~/.local/bin
   ln -sf "$(pwd)/zig-out/bin/help" ~/.local/bin/help
   # Add ~/.local/bin to PATH if not already there:
   echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc  # or ~/.zshrc
   source ~/.bashrc  # or restart your shell
   ```

   **Option C: Copy to system directory:**
   ```bash
   sudo cp zig-out/bin/help /usr/local/bin/help
   # Static copy - you'll need to repeat after rebuilding
   ```

   **Option D: Add project directory to PATH:**
   ```bash
   echo 'export PATH="'$(pwd)'/zig-out/bin:$PATH"' >> ~/.bashrc  # or ~/.zshrc
   echo 'alias help="'$(pwd)'/zig-out/bin/help"' >> ~/.bashrc
   source ~/.bashrc  # or restart your shell
   ```

4. **Verify installation:**
   ```bash
   # Check if the command is available
   which help
   
   # Test with simulation mode (no API key needed)
   LOCALHELP_LLM_PROVIDER=simulation help git status 'what does this show me'
   
   # Check version/help (once we add --help support)
   help git --help  # Should show usage information
   ```

### Basic Usage

```bash
# Get help with a command
help <command> [subcommand] [args...] 'your question here'

# Examples
help git reset 'I want to unstage my changes but keep them'
help docker ps 'show only running containers'  
help rsync 'how do I sync folders safely'
help tar 'extract a specific file from an archive'
```

## Configuration

Help uses environment variables for configuration:

### API Provider Setup

#### OpenRouter (Recommended)

OpenRouter provides access to multiple AI models including Claude, GPT-4, and others:

```bash
export LOCALHELP_LLM_PROVIDER=openrouter
export LOCALHELP_API_KEY=sk-or-v1-your-key-here  # Optional if using keychain
export LOCALHELP_MODEL=anthropic/claude-3.5-sonnet  # Optional
```

**Get your API key:** [https://openrouter.ai/keys](https://openrouter.ai/keys)

#### macOS Keychain Integration

On macOS, Help can securely store and retrieve API keys from the system keychain, eliminating the need to store sensitive keys in environment variables or shell profiles.

**Store your API key in keychain:**
```bash
# OpenRouter
security add-generic-password -a "$(whoami)" -s "localhelp-openrouter" -w "sk-or-your-api-key-here"

# OpenAI  
security add-generic-password -a "$(whoami)" -s "localhelp-openai" -w "sk-your-api-key-here"

# Anthropic
security add-generic-password -a "$(whoami)" -s "localhelp-anthropic" -w "sk-ant-your-api-key-here"
```

**Key resolution priority:**
1. `LOCALHELP_API_KEY` environment variable (highest priority)
2. macOS keychain (automatic fallback on macOS)  
3. No key available (shows setup instructions)

**Manage keychain entries:**
```bash
# View stored key (shows attributes, not the key itself)
security find-generic-password -a "$(whoami)" -s "localhelp-openrouter"

# Update existing key
security add-generic-password -a "$(whoami)" -s "localhelp-openrouter" -w "new-api-key" -U

# Delete key
security delete-generic-password -a "$(whoami)" -s "localhelp-openrouter"
```

**Benefits of keychain storage:**
- ✅ Secure storage with system encryption
- ✅ No API keys in shell history or dotfiles  
- ✅ Automatic access across terminal sessions
- ✅ Integrated with macOS security policies
- ✅ Easy to revoke or update

#### OpenAI

```bash
export LOCALHELP_LLM_PROVIDER=openai
export LOCALHELP_API_KEY=sk-your-openai-key-here  # Optional if using keychain
export LOCALHELP_MODEL=gpt-4  # Optional
```

#### Anthropic

```bash
export LOCALHELP_LLM_PROVIDER=anthropic
export LOCALHELP_API_KEY=sk-ant-your-anthropic-key-here  # Optional if using keychain
export LOCALHELP_MODEL=claude-3-5-sonnet-20241022  # Optional
```

#### Local LLM (Ollama, etc.)

```bash
export LOCALHELP_LLM_PROVIDER=local
export LOCALHELP_API_URL=http://localhost:11434
export LOCALHELP_MODEL=llama2  # Or your preferred local model
```

#### Simulation Mode (No API Key Required)

```bash
export LOCALHELP_LLM_PROVIDER=simulation
# Uses hardcoded responses for testing - no API key needed
```

### Model Selection

#### OpenRouter Models

OpenRouter provides access to many models. Popular choices:

```bash
# Claude models (recommended)
export LOCALHELP_MODEL=anthropic/claude-3.5-sonnet      # Default, best balance
export LOCALHELP_MODEL=anthropic/claude-3-opus          # Most capable
export LOCALHELP_MODEL=anthropic/claude-3-haiku         # Fastest, cheapest

# OpenAI models
export LOCALHELP_MODEL=openai/gpt-4                     # GPT-4
export LOCALHELP_MODEL=openai/gpt-4-turbo               # GPT-4 Turbo
export LOCALHELP_MODEL=openai/gpt-3.5-turbo             # Cheaper option

# Other providers
export LOCALHELP_MODEL=google/gemini-pro                # Google Gemini
export LOCALHELP_MODEL=meta-llama/llama-2-70b-chat      # Llama 2
```

See [OpenRouter models](https://openrouter.ai/models) for the full list.

## Examples

### Git Operations

```bash
# Unstage changes
help git reset 'I want to unstage my changes but keep them'

# Undo last commit
help git reset 'I made a mistake in my last commit and want to undo it'

# Cherry-pick commits
help git cherry-pick 'how do I apply specific commits from another branch'
```

### Docker Management

```bash
# Container inspection
help docker ps 'show only running containers with their ports'

# Image cleanup
help docker 'remove all unused images and containers'

# Volume management
help docker volume 'list all volumes and their sizes'
```

### File Operations

```bash
# Find files
help find 'search for files modified in the last 24 hours'

# Archive operations
help tar 'create a compressed archive excluding certain directories'

# Permission changes
help chmod 'make a script executable for everyone'
```

### Network Debugging

```bash
# Network connectivity
help ping 'test if a server is reachable and measure latency'

# Port scanning
help netstat 'show which processes are listening on which ports'

# DNS lookup
help dig 'find all DNS records for a domain'
```

## Advanced Usage

### Environment Configuration

Create a shell profile configuration:

```bash
# Add to ~/.bashrc, ~/.zshrc, etc.
export LOCALHELP_LLM_PROVIDER=openrouter
export LOCALHELP_API_KEY=sk-or-v1-your-key-here
export LOCALHELP_MODEL=anthropic/claude-3.5-sonnet

# Optional: Create an alias
alias h='help'
```

### Safety Features

Help includes several safety features:

- **Confirmation prompts** - Always asks before executing commands
- **Command explanation** - Shows what the command will do
- **Warning messages** - Highlights potentially destructive operations
- **Dry-run mentality** - Focuses on education over execution

### Response Format

Help provides structured responses:

```
🤖 AI Assistant Response:
═══════════════════════════

📋 EXPLANATION:
Clear explanation of what you want to achieve

💻 RECOMMENDED COMMAND:
exact-command-to-run

⚠️  WARNINGS:
Important caveats and potential issues

💡 ADDITIONAL INFO:
Helpful context and related information

═══════════════════════════

🚀 Execute Command?
Command: exact-command-to-run
Run this command? (y/N):
```

## Troubleshooting

### Common Issues

**"Command not found: help"**
- Make sure you completed the installation step 3 (system-wide setup)
- Check if the symlink exists: `ls -la /usr/local/bin/help` or `ls -la ~/.local/bin/help`
- Verify PATH includes the installation directory: `echo $PATH`
- Try running with full path: `./zig-out/bin/help`
- For ~/.local/bin, ensure it's in your PATH: `export PATH="$HOME/.local/bin:$PATH"`

**"Permission denied" during installation**
- For /usr/local/bin: Use `sudo` for the symlink command
- For ~/.local/bin: No sudo needed, but ensure the directory exists
- Check file permissions: `ls -la zig-out/bin/help`

**"No man page found"**
- The command might not be installed on your system
- Try with a different command that you know exists (like `git`, `ls`, `grep`)
- The tool will still provide AI assistance without the man page

**"API request failed"**
- Check your API key is correct and not expired
- Verify your internet connection
- Ensure you have sufficient API credits/quota
- Try switching to simulation mode for testing: `LOCALHELP_LLM_PROVIDER=simulation`

**Symlink issues after rebuilding**
- If you used Option A or B (symlinks), they should automatically point to the new binary
- If you used Option C (copy), you need to copy again after rebuilding
- Rebuild and reinstall: `zig build && zig build install`

### Debug Mode

For debugging API issues:

```bash
# The tool will show error messages for failed API calls
# Check the output for specific error details
```

### Testing Configuration

Test your setup with simulation mode:

```bash
LOCALHELP_LLM_PROVIDER=simulation help git status 'show me what this does'
```

## Development

### Building from Source

Requirements:
- Zig 0.15.0-dev.936 or later

```bash
git clone [<repository-url>](https://github.com/MarkMarine/help)
cd help
zig build
```

### Testing

```bash
# Run unit tests
zig build test

# Test with different providers
LOCALHELP_LLM_PROVIDER=simulation zig build run -- git reset 'test query'
```

### Project Structure

```
help/
├── src/
│   ├── main.zig          # CLI entry point
│   └── root.zig          # Core logic and LLM integration
├── build.zig             # Build configuration
├── build.zig.zon         # Package manifest
└── README.md             # This file
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with different providers
5. Submit a pull request

## License

[Add your license here]

## Support

- Report issues on GitHub
- Check the [CLAUDE.md](CLAUDE.md) file for development guidance
- Test with simulation mode first for any configuration issues

---

**Pro Tip:** Start with simulation mode to learn the interface, then upgrade to OpenRouter for real AI assistance. The combination of man pages + AI makes even complex command line tools approachable!
