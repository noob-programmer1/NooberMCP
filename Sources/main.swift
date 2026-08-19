import Foundation
import Network

// NooberMCP: MCP server + HTTP API for iOS & Android app testing.
// Works with any AI tool — Claude Code, Cursor, Codex, Windsurf, or custom.
//
// MCP: reads/writes JSON-RPC over stdio (standard MCP transport)
// HTTP: localhost:8686 (configurable via NOOBER_PORT env var)

let server = MCPServer()

// Start HTTP API server (for Cursor, Codex, custom tools, NoobQA GUI)
let httpServer = HTTPServer(mcpServer: server)
httpServer.start()

// Start MCP stdio server (for Claude Code, Windsurf)
server.run()

// Keep the process alive for async network operations
dispatchMain()
