/// Default `hc` location: where the herdr-core installer puts it.
const kDefaultHcBin = '~/.local/bin/hc';

/// Which herdr generation a host runs, and so which CLI drover drives.
enum HerdrBackend {
  /// herdr 1 (the TUI): the `herdr` CLI.
  herdr,

  /// Herdr 2 (herdr-core, behind the Herdr desktop app): the `hc` CLI.
  hc;

  static HerdrBackend fromName(String? name) => name == hc.name ? hc : herdr;
}
