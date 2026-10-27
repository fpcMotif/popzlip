# popzlip

**popzlip** is an ultra-lightweight, high-performance **PopClip** alternative written in **Zig** with **NanoUI** for macOS. It simulates the instant text-selection pill toolbar with <1ms latency, 5x–16x lower memory consumption than Swift/Electron alternatives, and native **Model Context Protocol (MCP)** server integration for AI coding agents.

---

## Acknowledgments & Thanks

popzlip is built on the shoulders of giants:
- **[PopClip](https://www.popclip.app/)** by [Pilotmoon Software](https://pilotmoon.com/): The original brilliant macOS text selection action tool. Its seamless interaction and ergonomics are the gold standard we emulate.
- **[Xpop](https://github.com/DongqiShen/Xpop)** by [Dongqi Shen](https://github.com/DongqiShen): An inspiring open-source Swift PopClip alternative demonstrating extension formats and accessibility grab strategies.
- **[NanoUI](https://github.com/justrach/nanoui)** by [Justin Rachlin](https://github.com/justrach): A minimalist, GPU-accelerated immediate-mode native UI framework in Zig.

---

## Key Features

- **28px Floating Pill Geometry**: Exact 1:1 parity with PopClip's 28.0 px floating window height, horizontal centering, screen-margin clamping, and top-edge flipping.
- **Core Action Suite**:
  - `>_` **Terminal**: Run selected command or script in zsh / Terminal.
  - `+` **Append to Clipboard**: Append highlighted text to current clipboard contents with a newline separator.
  - 📝 **Notes**: Append selected text directly into Apple Notes.
  - 🔗 **Open Link**: Contextual action when selected text is a URL.
  - 🔍 **Search**: Web search via Google or custom search engine.
  - 🧮 **Math Calculator**: Tokenizes and evaluates arithmetic expressions (`125 * 4 + 18` &rarr; `= 518`).
  - 🔤 **Case Transforms**: UPPERCASE, lowercase, Title Case.
  - 🖋️ **Markdown Formatting**: Bold (`**`), Italic (`*`), Inline Code (`` ` ``).
  - 📖 **Dictionary / Define**: Word lookup via macOS Dictionary Services.
  - 📊 **Word & Char Stats**: Live word and character counting.
- **AI Agent Integration (Native MCP Server)**:
  - Run `popzlip --mcp` to expose a standard JSON-RPC 2.0 Model Context Protocol server over `stdio`.
  - Enables AI coding agents (Claude Code, Cursor, Devin, Windsurf) to read live user selections, inspect clipboard history, trigger actions, and show popups.
- **Interactive CLI & Config**:
  - `popzlip config get <key>` / `popzlip config set <key> <val>`
  - `popzlip append "<text>"`
  - `popzlip --simulate "<text>"`
  - `popzlip --bench`
- **Zero Overhead & Microsecond Speed**:
  - Entire binary is a single self-contained executable.
  - Zero helper daemon processes required.
  - Zero garbage collection pauses.

---

## Memory & Performance Benchmark

Measured against live running PopClip (PID 5958) on macOS:

| Metric | Original PopClip (Swift / Cocoa) | popzlip (Zig + NanoUI) | Improvement |
| :--- | :--- | :--- | :--- |
| **Main Process RSS** | 35.17 MB | 2.89 MB (Engine) / 9.22 MB (Full GPU UI) | **~4x – 12x lower** |
| **Helper Process RSS** | 12.34 MB (`PopClipEventMonitor`) | None (0 MB) | **Zero helper overhead** |
| **Total Resident Memory** | **47.51 MB** | **9.22 MB** | **~5.1x lower memory** |
| **Heap Allocation per Selection** | ~250 KB | 1.17 KB (1201 bytes) | **210x lower heap usage** |
| **Selection to Popup Latency** | ~15 ms | < 1 ms | **15x faster** |
| **Idle CPU** | 0.0% | 0.0% | Parity |

---

## Building & Testing

### Prerequisites
- macOS 13+ (Apple Silicon or Intel)
- [Zig](https://ziglang.org/) (0.16.0 or compatible)
- Xcode Command Line Tools (`xcrun`, `xctest`, `clang`)

### Build
```bash
# Build binary (zig-out/bin/popclip-zig) and dylib (zig-out/lib/libzigpopclip.dylib)
zig build

# Run unit tests
zig test src/actions.zig
zig test src/placement.zig
zig test src/config.zig
zig test src/mcp.zig
zig test src/macos.zig
```

### Apple XCTest Verification Suite
```bash
# Build the XCTest bundle and run with Apple's test runner
xcrun xctest xctest/PopClipZigTests.xctest
```

---

## AI Agent Integration (MCP)

Add `popzlip` to your MCP settings (e.g. `claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "popzlip": {
      "command": "/path/to/popzlip",
      "args": ["--mcp"]
    }
  }
}
```

Exposed MCP Tools:
- `popclip_get_selection`: Read active highlighted selection & frontmost app.
- `popclip_list_actions`: Inspect available actions for arbitrary text.
- `popclip_trigger_action`: Execute an action (`copy`, `append`, `open_url`, `calculate`, etc.) on text.
- `popclip_read_clipboard`: Read current clipboard content.
- `popclip_append_clipboard`: Append text with newline to clipboard.
- `popclip_get_stats`: Live process metrics (memory RSS, latency, status).

---

## License

MIT License. See [LICENSE](LICENSE) for details.
