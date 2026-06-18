/// An exclusive selection of the IP address family to use when pinging a host.
///
/// Choosing a value selects exactly one IP address family, and the library
/// attempts ONLY that family. This mirrors the semantics of the native
/// `ping`/`ping6` commands (the `-4`/`-6` flags): a host is resolved and
/// pinged using the chosen family, and the operation fails rather than
/// silently falling back to the other family.
///
/// There is deliberately NO third "auto", "dual-stack", or "prefer" value.
/// The selection is always exclusive and unambiguous.
///
/// The name `IpVersion` was chosen over `IpMode` because "mode" implies
/// behavioral modes (such as prefer/auto/dual-stack) that this library does
/// not offer; the only choice on offer is which single IP version to use.
enum IpVersion {
  /// Selects IPv4 only.
  ///
  /// This EXCLUDES IPv6 — it does NOT mean "prefer IPv4" or "dual-stack".
  /// The host is resolved and pinged over IPv4 exclusively (matching the
  /// native `ping -4` semantics), and the operation fails rather than
  /// falling back to IPv6.
  ///
  /// This is the default selection.
  ipv4,

  /// Selects IPv6 only.
  ///
  /// This EXCLUDES IPv4 — it does NOT mean "prefer IPv6" or "dual-stack".
  /// The host is resolved and pinged over IPv6 exclusively (matching the
  /// native `ping6`/`ping -6` semantics), and the operation fails rather
  /// than falling back to IPv4.
  ///
  /// Note: IPv6 is not supported on Windows, which surfaces an explicit
  /// error rather than silently falling back.
  ipv6,
}
