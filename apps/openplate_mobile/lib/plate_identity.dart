/// Preserve German plate identities. MÜ, MU and M are not interchangeable.
String normalizePlate(String value) => value
    .toUpperCase()
    .replaceAll('A\u0308', 'Ä')
    .replaceAll('O\u0308', 'Ö')
    .replaceAll('U\u0308', 'Ü')
    .replaceAll(RegExp('[^A-ZÄÖÜ0-9]'), '');
