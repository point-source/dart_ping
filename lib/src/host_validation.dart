import 'dart:io';

/// Matches a single hostname label: ASCII letters, digits, underscore, and
/// interior hyphens. A label may NOT start or end with a hyphen (RFC 952/1123),
/// which also prevents a host shaped like a `ping` option flag (e.g. `-f`,
/// `-c1000000`, `--flood`): `host` is handed to the subprocess as an argument,
/// so a leading-dash value would be read as a flag rather than a target —
/// argument injection, adjacent to the shell-injection this guard closes.
/// Punycode/IDN labels (`xn--…`) start with a letter and so are covered. No
/// shell metacharacter, whitespace or control character can match.
final RegExp _hostnameLabel =
    RegExp(r'^[A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?$');

/// Matches an IPv6 zone/scope id (the part after `%` in `fe80::1%eth0`): an
/// interface name or numeric index. Restricted to characters that are inert to
/// any shell — `%` itself is admitted ONLY as the delimiter, never freely.
final RegExp _zoneId = RegExp(r'^[A-Za-z0-9_.-]+$');

/// Whether [host] is a syntactically valid hostname or IPv4/IPv6 literal and is
/// therefore safe to launch as a ping target — data, never a command.
///
/// This is an ALLOW-LIST: a host passes only by matching a hostname or IP
/// literal shape, so anything containing a character with no place in a
/// hostname/IP literal — shell metacharacters (`&`, `|`, `<`, `>`, `^`, `(`,
/// `)`, `"`, `'`, `` ` ``, `;`, `$`, `%`, backslash), whitespace, or any control
/// character — is refused by construction. A blacklist of shell metacharacters
/// is deliberately avoided: a single missed metacharacter would silently reopen
/// the hole, and different shells differ (§spec:host-input-is-data).
///
/// Parse-only and network-free: no DNS resolution is performed.
bool isHostSafe(String host) {
  if (host.isEmpty) return false;

  // A scoped/zoned IPv6 literal: `<ipv6>%<zone>`. This MUST be decided before
  // the plain `InternetAddress.tryParse` below, because that parse's zone
  // handling is environment-dependent: on macOS it accepts a zoned IPv6 with an
  // arbitrary, UNVALIDATED zone string, so a dangerous zone such as
  // `fe80::1%a&b` would parse as a valid IPv6 address and wrongly return `true`
  // (on Linux/Windows the same parse is strict and returns null). Deciding every
  // `%`-bearing host here — validating the two parts ourselves: the body must
  // parse as an IPv6 literal and the zone must be shell-safe — makes the result
  // DETERMINISTIC and portable across platforms. This is the ONLY position in
  // which `%` is admitted: a free-standing `%` (e.g. `8.8.8.8%calc`, `%VAR%`)
  // does not reach a valid IPv6 body and is refused, and any zone carrying a
  // metacharacter fails `_zoneId`.
  final pct = host.indexOf('%');
  if (pct > 0) {
    final body = host.substring(0, pct);
    final zone = host.substring(pct + 1);
    final bodyAddr = InternetAddress.tryParse(body);
    return bodyAddr != null &&
        bodyAddr.type == InternetAddressType.IPv6 &&
        zone.isNotEmpty &&
        _zoneId.hasMatch(zone);
  }

  // A clean IPv4/IPv6 literal (no zone). `InternetAddress.tryParse` accepts
  // these and rejects anything with stray characters. Any `%`-bearing host has
  // already been decided above, so this only ever sees an unzoned candidate.
  final literal = InternetAddress.tryParse(host);
  if (literal != null &&
      (literal.type == InternetAddressType.IPv4 ||
          literal.type == InternetAddressType.IPv6)) {
    return true;
  }

  // Otherwise it must be a syntactically valid hostname: dot-separated labels,
  // each a run of hostname-safe characters. A single trailing dot (the FQDN
  // root) is tolerated.
  //
  // Bracketed IPv6 (`[::1]`) is deliberately NOT accepted: the brackets are URL
  // authority notation, not a bare ping target — `host` is passed verbatim to
  // the subprocess, where `ping [::1]` fails as an unknown host on every
  // platform. The unbracketed literal (`::1`) is the supported form (handled
  // above). The `[`/`]` fail the label charset below, so such input is refused.
  final name =
      host.endsWith('.') ? host.substring(0, host.length - 1) : host;
  if (name.isEmpty || name.length > 253) return false;
  for (final label in name.split('.')) {
    if (label.isEmpty || label.length > 63 || !_hostnameLabel.hasMatch(label)) {
      return false;
    }
  }
  return true;
}

/// Throws an [ArgumentError] when [host] is not a syntactically valid hostname
/// or IP literal — i.e. when it carries a character that could be interpreted by
/// a shell. A safe host returns normally; no DNS is performed.
///
/// Centralised here so every entry point — the [Ping] factory, the core
/// platform classes (via `BasePing`), and the iOS `IosPing` constructor — fails
/// fast with the identical error before any process launches, mirroring
/// [validateAddressFamily]. This makes a `host` value data on every platform and
/// both the default and `forceCodepage` launch paths, so a host reaching the
/// Windows `chcp 437 && ping …` shell chain has already been proven inert
/// (§spec:host-input-is-data, §spec:forcecodepage-injection-closed).
void validateHostSafety(String host) {
  if (!isHostSafe(host)) {
    throw ArgumentError.value(
      host,
      'host',
      'Unsafe or invalid host value: a host must be a syntactically valid '
          'hostname or IPv4/IPv6 literal, and may not contain shell '
          'metacharacters, whitespace, or control characters',
    );
  }
}
