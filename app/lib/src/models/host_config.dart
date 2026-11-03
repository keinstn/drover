import '../herdr/herdr_backend.dart';

/// Default path to the `herdr` binary on the remote host; a `~` is left
/// unquoted when building commands so the remote shell expands it.
const kDefaultHerdrBin = '~/.local/bin/herdr';

class HostConfig {
  const HostConfig({
    this.name,
    required this.host,
    this.port = 22,
    required this.user,
    required this.privateKeyPem,
    this.passphrase,
    this.herdrBin = kDefaultHerdrBin,
    this.hostId,
    this.hostKeyFingerprint,
    this.backendMode = HostBackendMode.auto,
    this.hcBin = kDefaultHcBin,
  });

  factory HostConfig.fromJson(Map<String, dynamic> json) {
    final mode = HostBackendMode.values.asNameMap()[json['backendMode']];
    // Before backendMode, a host ran one backend (`backend`) and `herdrBin`
    // held that backend's CLI.
    final legacyHc = mode == null && json['backend'] == HerdrBackend.hc.name;
    final bin = json['herdrBin'] as String?;
    return HostConfig(
      name: json['name'] as String?,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      user: json['user'] as String,
      privateKeyPem: json['privateKeyPem'] as String,
      passphrase: json['passphrase'] as String?,
      herdrBin: (legacyHc ? null : bin) ?? kDefaultHerdrBin,
      hostId: json['hostId'] as String?,
      hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
      backendMode: legacyHc ? HostBackendMode.hc : mode ?? HostBackendMode.auto,
      hcBin: (legacyHc ? bin : json['hcBin'] as String?) ?? kDefaultHcBin,
    );
  }

  /// Optional user-facing label; when absent, UI falls back to [displayName].
  final String? name;
  final String host;
  final int port;
  final String user;
  final String privateKeyPem;
  final String? passphrase;

  /// herdr 1's CLI.
  final String herdrBin;

  /// Herdr 2's CLI.
  final String hcBin;
  final String? hostId;
  final String? hostKeyFingerprint;

  /// Which backends drover talks to on this host.
  final HostBackendMode backendMode;

  /// The label shown in host lists and the app bar: [name] when set,
  /// otherwise `user@host`.
  String get displayName {
    final name = this.name;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return '$user@$host';
  }

  /// Whether [other] describes the same connection: host, port, user,
  /// privateKeyPem, passphrase, herdrBin, hcBin, and backendMode all match. Excludes [name]
  /// (cosmetic), [hostId], and [hostKeyFingerprint] — the fingerprint is
  /// learned via TOFU pinning after the runner is built, so including it
  /// would force a reconnect right after every first-connect pin.
  bool sameConnection(HostConfig other) =>
      host == other.host &&
      port == other.port &&
      user == other.user &&
      privateKeyPem == other.privateKeyPem &&
      passphrase == other.passphrase &&
      herdrBin == other.herdrBin &&
      hcBin == other.hcBin &&
      backendMode == other.backendMode;

  HostConfig withHostId(String? value) => HostConfig(
    name: name,
    host: host,
    port: port,
    user: user,
    privateKeyPem: privateKeyPem,
    passphrase: passphrase,
    herdrBin: herdrBin,
    hostId: value,
    hostKeyFingerprint: hostKeyFingerprint,
    backendMode: backendMode,
    hcBin: hcBin,
  );

  HostConfig withHostKeyFingerprint(String? value) => HostConfig(
    name: name,
    host: host,
    port: port,
    user: user,
    privateKeyPem: privateKeyPem,
    passphrase: passphrase,
    herdrBin: herdrBin,
    hostId: hostId,
    hostKeyFingerprint: value,
    backendMode: backendMode,
    hcBin: hcBin,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'host': host,
    'port': port,
    'user': user,
    'privateKeyPem': privateKeyPem,
    'passphrase': passphrase,
    'herdrBin': herdrBin,
    'hostId': hostId,
    'hostKeyFingerprint': hostKeyFingerprint,
    'backendMode': backendMode.name,
    'hcBin': hcBin,
  };
}
