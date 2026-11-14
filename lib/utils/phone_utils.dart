/// Utility class for validating and normalizing Ethiopian phone numbers.
class PhoneUtils {
  /// Normalizes an Ethiopian phone number to a standard 10-digit format starting with '09' or '07'.
  ///
  /// Strips all whitespace, hyphens, and parentheses.
  /// Handles formats such as:
  /// - "+251911223344" -> "0911223344"
  /// - "+251711223344" -> "0711223344"
  /// - "251911223344"  -> "0911223344"
  /// - "911223344"     -> "0911223344"
  /// - "0911223344"    -> "0911223344"
  /// - "0711223344"    -> "0711223344"
  ///
  /// Returns the normalized 10-digit string starting with "09" or "07".
  /// Returns null if the input is invalid in length or prefix.
  static String? normalizeEthiopianPhone(String input) {
    // 1. Strip all whitespace, hyphens, and parentheses
    String cleaned = input.replaceAll(RegExp(r'[\s\-()]'), '');

    // 2. Handle international prefixes
    if (cleaned.startsWith('+251')) {
      cleaned = cleaned.substring(4);
    } else if (cleaned.startsWith('251')) {
      cleaned = cleaned.substring(3);
    }

    // 3. If starting with 9 or 7 and length is 9, prepend '0'
    if ((cleaned.startsWith('9') || cleaned.startsWith('7')) && cleaned.length == 9) {
      cleaned = '0$cleaned';
    }

    // 4. Must be exactly 10 digits starting with '09' or '07'
    final regExp = RegExp(r'^(09|07)\d{8}$');
    if (!regExp.hasMatch(cleaned)) {
      return null;
    }

    return cleaned;
  }

  /// Returns true if [input] can be successfully normalized into a valid Ethiopian phone number.
  static bool isValidEthiopianPhone(String input) {
    return normalizeEthiopianPhone(input) != null;
  }
}
