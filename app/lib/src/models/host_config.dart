import '../herdr/herdr_backend.dart';

/// Default path to the `herdr` binary on the remote host; a `~` is left
/// unquoted when building commands so the remote shell expands it.
const kDefaultHerdrBin = '~/.local/bin/herdr';

/// The CLI path a host starts with for [backend].
String defaultBinFor(HerdrBackend backend) =>
    backend == HerdrBackend.hc ? kDefaultHcBin : kDefaultHerdrBin;

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
    this.backend = HerdrBackend.herdr,
  });

  factory HostConfig.fromJson(Map<String, dynamic> json) {
    final backend = HerdrBackend.fromName(json['backend'] as String?);
    return HostConfig(
      name: json['name'] as String?,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      user: json['user'] as String,
      privateKeyPem: json['privateKeyPem'] as String,
      passphrase: json['passphrase'] as String?,
      herdrBin: json['herdrBin'] as String? ?? defaultBinFor(backend),
      hostId: json['hostId'] as String?,
      hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
      backend: backend,
    );
  }

  /// Optional user-facing label; when absent, UI falls back to [displayName].
  final String? name;
  final String host;
  final int port;
  final String user;
  final String privateKeyPem;
  final String? passphrase;
  final String herdrBin;
  final String? hostId;
  final String? hostKeyFingerprint;

  /// Which herdr generation the host runs; picks the client drover builds.
  final HerdrBackend backend;

  /// The label shown in host lists and the app bar: [name] when set,
  /// otherwise `user@host`.
  String get displayName {
    final name = this.name;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return '$user@$host';
  }

  /// Whether [other] describes the same connection: host, port, user,
  /// privateKeyPem, passphrase, herdrBin, and backend all match. Excludes [name]
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
      backend == other.backend;

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
    backend: backend,
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
    backend: backend,
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
    'backend': backend.name,
  };
}
