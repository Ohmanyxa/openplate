import 'dart:io';

/// HTTP is allowed only for the application-encrypted local HA connection.
bool isHomeAssistantUrl(Uri uri) {
  if (uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return false;
  }
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  final host = uri.host.replaceAll('[', '').replaceAll(']', '').toLowerCase();
  final address = InternetAddress.tryParse(host);
  if (address == null) {
    return !host.contains(':') &&
        (!host.contains('.') ||
            host.endsWith('.local') ||
            host.endsWith('.lan') ||
            host.endsWith('.home.arpa'));
  }
  if (address.isLoopback || address.isLinkLocal) return true;
  final bytes = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return bytes[0] == 10 ||
        (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
        (bytes[0] == 192 && bytes[1] == 168);
  }
  return (bytes[0] & 0xfe) == 0xfc;
}
