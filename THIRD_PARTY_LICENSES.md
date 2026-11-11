# Third-party notices

NooberMCP 2.x no longer redistributes third-party binaries. Earlier releases bundled AXe
and Meta's IDB frameworks; both have been replaced by native code in `Sources/Native/`.

## Acknowledgements

The native simulator layer was written for this project, following protocols and
techniques documented in these open-source projects:

- **meta/idb** — the `dtuhidd` XPC transport (message envelope, `IndigoDigitizerEvent`,
  keyboard/button payloads, guest service lookup via `xpc_endpoint_create_mach_port_4sim`)
  and HID usage tables. MIT — https://github.com/meta/idb/blob/main/LICENSE
- **EvanBacon/serve-sim** — the Xcode 27 SimulatorKit location, the
  `IndigoHIDMessageForMouseNSEvent` signature, and `AXPTranslator` bridging with point-grid
  discovery. Apache-2.0 — https://github.com/EvanBacon/serve-sim/blob/main/LICENSE

## NooberProbe

`Bundled/NooberProbe.dylib` is part of this project and is covered by the MIT license in
[LICENSE](LICENSE).
