/// Default `hc` location: where the herdr-core installer puts it.
const kDefaultHcBin = '~/.local/bin/hc';

/// Prefix on every id `HcClient` hands out, so one host's herdr 1 and Herdr 2
/// ids never collide and a combined client can route by id alone.
const kHcIdPrefix = 'hc:';

/// One herdr generation, and so which CLI a client drives.
enum HerdrBackend {
  /// herdr 1 (the TUI): the `herdr` CLI.
  herdr,

  /// Herdr 2 (herdr-core, behind the Herdr desktop app): the `hc` CLI.
  hc,
}

/// Which backends a host's client talks to.
enum HostBackendMode {
  /// Both: herdr 1 if `herdr` is installed, Herdr 2 if its core is running.
  auto,

  /// herdr 1 only.
  herdr,

  /// Herdr 2 only (starts the core if needed, like `hc` itself).
  hc,
}

/// The backend that issued [id]: Herdr 2 ids carry [kHcIdPrefix].
HerdrBackend backendOfId(String id) =>
    id.startsWith(kHcIdPrefix) ? HerdrBackend.hc : HerdrBackend.herdr;

/// [id] as shown to a person: without [kHcIdPrefix]. Display only — routing
/// needs the prefix.
String displayId(String id) =>
    id.startsWith(kHcIdPrefix) ? id.substring(kHcIdPrefix.length) : id;
