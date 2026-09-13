/// Renders a stored host path into a command the user can paste into their
/// own shell. `~` is expanded to `$HOME` because the rest of the path is
/// single-quoted against spaces, and quoting would defeat tilde expansion.
String shellCommandPath(String value) => value.startsWith('~/')
    ? '\$HOME/${_shellQuote(value.substring(2))}'
    : _shellQuote(value);

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
