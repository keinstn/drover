/// One entry in a remote directory listing.
class RemoteDirEntry {
  const RemoteDirEntry({required this.name, required this.isDirectory});

  final String name;
  final bool isDirectory;
}
