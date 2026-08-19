# Third-party licenses

The NooberMCP release archive redistributes the following third-party components
under `Bundled/`. Each is used unmodified and remains under its own license.

## AXe

Simulator automation CLI (`Bundled/axe`), used for taps, swipes, text entry, and
accessibility inspection on iOS simulators.

- Upstream: https://github.com/cameroncooke/AXe
- Version bundled: v1.5.2
- License: MIT — see https://github.com/cameroncooke/AXe/blob/main/LICENSE

## Meta IDB frameworks

`Bundled/Frameworks/` contains `FBControlCore.framework`,
`FBDeviceControl.framework`, `FBSimulatorControl.framework`, and
`XCTestBootstrap.framework`. These originate from Meta's iOS Development Bridge
and ship as AXe's runtime dependencies.

- Upstream: https://github.com/facebook/idb
- License: MIT — see https://github.com/facebook/idb/blob/main/LICENSE
- Additional attribution notices are carried in AXe's `THIRD_PARTY_LICENSES`:
  https://github.com/cameroncooke/AXe/blob/main/THIRD_PARTY_LICENSES

## NooberProbe

`Bundled/NooberProbe.dylib` and `Bundled/NooberProbe_swift.dylib` are part of
this project and are covered by the MIT license in [LICENSE](LICENSE).
