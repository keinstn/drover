/// Default path to the `herdr` binary on the remote host; a `~` is left
/// unquoted when building commands so the remote shell expands it.
const kDefaultHerdrBin = '~/.local/bin/herdr';

class HostConfig {
  const HostConfig({
    required this.host,
    this.port = 22,
    required this.user,
    required this.privateKeyPem,
    this.passphrase,
    this.herdrBin = kDefaultHerdrBin,
    this.hostId,
  });

  factory HostConfig.fromJson(Map<String, dynamic> json) {
    return HostConfig(
      host: json['host'] as String,
      port: json['port'] as int? ?? 22,
      user: json['user'] as String,
      privateKeyPem: json['privateKeyPem'] as String,
      passphrase: json['passphrase'] as String?,
      herdrBin: json['herdrBin'] as String? ?? kDefaultHerdrBin,
      hostId: json['hostId'] as String?,
    );
  }

  final String host;
  final int port;
  final String user;
  final String privateKeyPem;
  final String? passphrase;
  final String herdrBin;
  final String? hostId;

  HostConfig withHostId(String? value) => HostConfig(
    host: host,
    port: port,
    user: user,
    privateKeyPem: privateKeyPem,
    passphrase: passphrase,
    herdrBin: herdrBin,
    hostId: value,
  );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'user': user,
    'privateKeyPem': privateKeyPem,
    'passphrase': passphrase,
    'herdrBin': herdrBin,
    'hostId': hostId,
  };
}
