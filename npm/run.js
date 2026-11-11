#!/usr/bin/env node

/**
 * noober-mcp — MCP server for iOS app testing.
 *
 * Downloads the NooberMCP release bundle for your platform and runs it.
 * Works with Claude Code, Cursor, Codex, Windsurf — any MCP client.
 *
 * Usage:
 *   npx noober-mcp
 *
 * Add to Claude Code:
 *   claude mcp add noober -- npx -y noober-mcp
 *
 * Add to Cursor (.cursor/mcp.json):
 *   { "mcpServers": { "noober": { "command": "npx", "args": ["-y", "noober-mcp"] } } }
 *
 * Environment variables:
 *   NOOBER_PORT=8686     HTTP API port (default 8686)
 *   NOOBER_MCP_BIN=path  Use a local NooberMCP build instead of downloading
 */

const { spawn, execFileSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');

const pkg = require('./package.json');
const VERSION = pkg.version;
const REPO = 'noob-programmer1/NooberMCP';

// The release asset is a tarball, not a bare binary: NooberMCP resolves the
// probe dylibs relative to its own location (<dir>/Bundled/...), so they must travel together.
const INSTALL_DIR = path.join(os.homedir(), '.noober-mcp', `v${VERSION}`);
const BINARY_PATH = path.join(INSTALL_DIR, 'NooberMCP');

function platformSlug() {
  if (os.platform() !== 'darwin') return null;
  return os.arch() === 'arm64' ? 'macos-arm64' : 'macos-x86_64';
}

function download(url, dest, redirectsLeft = 5) {
  return new Promise((resolve, reject) => {
    https
      .get(url, { headers: { 'User-Agent': `noober-mcp/${VERSION}` } }, (response) => {
        const { statusCode, headers } = response;

        if (statusCode >= 300 && statusCode < 400 && headers.location) {
          response.resume();
          if (redirectsLeft === 0) return reject(new Error('too many redirects'));
          return download(headers.location, dest, redirectsLeft - 1).then(resolve, reject);
        }

        if (statusCode !== 200) {
          response.resume();
          return reject(new Error(`HTTP ${statusCode} for ${url}`));
        }

        const file = fs.createWriteStream(dest);
        response.pipe(file);
        file.on('error', reject);
        file.on('finish', () => file.close(() => resolve()));
      })
      .on('error', reject);
  });
}

async function ensureBinary() {
  const override = process.env.NOOBER_MCP_BIN;
  if (override) {
    if (!fs.existsSync(override)) {
      console.error(`NOOBER_MCP_BIN points at a missing file: ${override}`);
      process.exit(1);
    }
    return override;
  }

  if (fs.existsSync(BINARY_PATH)) return BINARY_PATH;

  const slug = platformSlug();
  if (!slug) {
    console.error(
      `noober-mcp supports macOS only (iOS simulators and Xcode live there). Detected ${os.platform()}/${os.arch()}.`
    );
    process.exit(1);
  }

  const asset = `noober-mcp-${slug}.tar.gz`;
  const url = `https://github.com/${REPO}/releases/download/v${VERSION}/${asset}`;
  const stagingDir = `${INSTALL_DIR}.tmp-${process.pid}`;
  const tarball = path.join(os.tmpdir(), `${asset}.${process.pid}`);

  console.error(`Downloading NooberMCP v${VERSION} (${slug})...`);
  fs.mkdirSync(path.dirname(INSTALL_DIR), { recursive: true });
  fs.mkdirSync(stagingDir, { recursive: true });

  try {
    await download(url, tarball);

    // A truncated or HTML error body would otherwise be unpacked and executed.
    const { size } = fs.statSync(tarball);
    if (size < 200000) throw new Error(`downloaded asset is only ${size} bytes`);

    execFileSync('tar', ['-xzf', tarball, '-C', stagingDir]);
    if (!fs.existsSync(path.join(stagingDir, 'NooberMCP'))) {
      throw new Error('release archive is missing the NooberMCP binary');
    }
    fs.chmodSync(path.join(stagingDir, 'NooberMCP'), 0o755);

    fs.renameSync(stagingDir, INSTALL_DIR);
    console.error(`Installed to ${INSTALL_DIR}`);
  } catch (err) {
    fs.rmSync(stagingDir, { recursive: true, force: true });
    console.error(`Failed to install NooberMCP: ${err.message}`);
    console.error(`Expected asset: ${url}`);
    console.error('Build from source instead: clone the repo, run swift build -c release,');
    console.error('then NOOBER_MCP_BIN=/path/to/.build/release/NooberMCP npx noober-mcp');
    process.exit(1);
  } finally {
    fs.rmSync(tarball, { force: true });
  }

  return BINARY_PATH;
}

async function main() {
  const binaryPath = await ensureBinary();

  const child = spawn(binaryPath, process.argv.slice(2), {
    stdio: 'inherit',
    env: { ...process.env },
  });

  child.on('exit', (code, signal) => {
    if (signal) process.kill(process.pid, signal);
    process.exit(code || 0);
  });
  process.on('SIGINT', () => child.kill('SIGINT'));
  process.on('SIGTERM', () => child.kill('SIGTERM'));
}

main();
