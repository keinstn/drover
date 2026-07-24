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
  });

  factory HostConfig.fromJson(Map<String, dynamic> json) {
    return HostConfig(
      name: json['name'] as String?,
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      user: json['user'] as String,
      privateKeyPem: json['privateKeyPem'] as String,
      passphrase: json['passphrase'] as String?,
      herdrBin: json['herdrBin'] as String? ?? kDefaultHerdrBin,
      hostId: json['hostId'] as String?,
      hostKeyFingerprint: json['hostKeyFingerprint'] as String?,
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

  /// The label shown in host lists and the app bar: [name] when set,
  /// otherwise `user@host`.
  String get displayName {
    final name = this.name;
    if (name != null && name.trim().isNotEmpty) return name.trim();
    return '$user@$host';
  }

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
  };
}
