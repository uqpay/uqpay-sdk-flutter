/// The billing countries the card form offers.
///
/// ### Why this table exists at all
///
/// Both native UQPAY SDKs read the ISO list from the platform
/// (`Locale.getISOCountries` on Android, `Locale.Region.isoRegions` on iOS)
/// precisely so that nobody hand-maintains one. Dart exposes no such table
/// and the SDK's pure-Dart design forbids a platform channel to reach it, so
/// the list is carried here — complete, not a subset.
///
/// The distinction matters. The shipped iOS SDK once had a **nine-entry**
/// lookup that returned `"US"` for everything it did not recognise, which
/// sent the wrong country to the issuer for every customer outside those
/// nine markets, silently, on every payment. The danger there was the silent
/// fallback, not the fact of a table: [UqpayBillingCountries.lookup] returns
/// `null` for an unknown code and the form refuses to submit without a real
/// selection, so a substitution cannot happen quietly.
///
/// Names are English; the SDK ships English strings. Codes are the
/// ISO 3166-1 alpha-2 values the confirm API expects in
/// `billing.address.country_code`.
library;

import 'package:flutter/foundation.dart';

/// One selectable billing country.
@immutable
class UqpayBillingCountry {
  /// Creates a country entry.
  const UqpayBillingCountry(this.code, this.name);

  /// ISO 3166-1 alpha-2, uppercase, e.g. `SG`.
  final String code;

  /// Display name, e.g. `Singapore`.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is UqpayBillingCountry && other.code == code && other.name == name;

  @override
  int get hashCode => Object.hash(code, name);

  @override
  String toString() => '$code ($name)';
}

/// The ISO 3166-1 country table, parsed once.
abstract final class UqpayBillingCountries {
  /// Every country and territory, sorted by display name.
  static final List<UqpayBillingCountry> all = _parse();

  /// The entry for [code] (case-insensitive), or `null` when the code is not
  /// a known ISO 3166-1 alpha-2 value. Never falls back to a default.
  static UqpayBillingCountry? lookup(String? code) {
    if (code == null || code.length != 2) {
      return null;
    }
    final upper = code.toUpperCase();
    for (final country in all) {
      if (country.code == upper) {
        return country;
      }
    }
    return null;
  }

  static List<UqpayBillingCountry> _parse() {
    final entries = <UqpayBillingCountry>[
      for (final row in _table)
        UqpayBillingCountry(row.substring(0, 2), row.substring(3)),
    ]..sort((a, b) => a.name.compareTo(b.name));
    return List<UqpayBillingCountry>.unmodifiable(entries);
  }

  // ISO 3166-1 alpha-2 as 'CC:Name'. One row per line so a missing or
  // altered entry shows up as a one-line diff.
  static const List<String> _table = <String>[
    'AD:Andorra',
    'AE:United Arab Emirates',
    'AF:Afghanistan',
    'AG:Antigua and Barbuda',
    'AI:Anguilla',
    'AL:Albania',
    'AM:Armenia',
    'AO:Angola',
    'AQ:Antarctica',
    'AR:Argentina',
    'AS:American Samoa',
    'AT:Austria',
    'AU:Australia',
    'AW:Aruba',
    'AX:Åland Islands',
    'AZ:Azerbaijan',
    'BA:Bosnia and Herzegovina',
    'BB:Barbados',
    'BD:Bangladesh',
    'BE:Belgium',
    'BF:Burkina Faso',
    'BG:Bulgaria',
    'BH:Bahrain',
    'BI:Burundi',
    'BJ:Benin',
    'BL:Saint Barthélemy',
    'BM:Bermuda',
    'BN:Brunei',
    'BO:Bolivia',
    'BQ:Caribbean Netherlands',
    'BR:Brazil',
    'BS:Bahamas',
    'BT:Bhutan',
    'BV:Bouvet Island',
    'BW:Botswana',
    'BY:Belarus',
    'BZ:Belize',
    'CA:Canada',
    'CC:Cocos (Keeling) Islands',
    'CD:Congo - Kinshasa',
    'CF:Central African Republic',
    'CG:Congo - Brazzaville',
    'CH:Switzerland',
    'CI:Côte d’Ivoire',
    'CK:Cook Islands',
    'CL:Chile',
    'CM:Cameroon',
    'CN:China',
    'CO:Colombia',
    'CR:Costa Rica',
    'CU:Cuba',
    'CV:Cape Verde',
    'CW:Curaçao',
    'CX:Christmas Island',
    'CY:Cyprus',
    'CZ:Czechia',
    'DE:Germany',
    'DJ:Djibouti',
    'DK:Denmark',
    'DM:Dominica',
    'DO:Dominican Republic',
    'DZ:Algeria',
    'EC:Ecuador',
    'EE:Estonia',
    'EG:Egypt',
    'EH:Western Sahara',
    'ER:Eritrea',
    'ES:Spain',
    'ET:Ethiopia',
    'FI:Finland',
    'FJ:Fiji',
    'FK:Falkland Islands',
    'FM:Micronesia',
    'FO:Faroe Islands',
    'FR:France',
    'GA:Gabon',
    'GB:United Kingdom',
    'GD:Grenada',
    'GE:Georgia',
    'GF:French Guiana',
    'GG:Guernsey',
    'GH:Ghana',
    'GI:Gibraltar',
    'GL:Greenland',
    'GM:Gambia',
    'GN:Guinea',
    'GP:Guadeloupe',
    'GQ:Equatorial Guinea',
    'GR:Greece',
    'GS:South Georgia and the South Sandwich Islands',
    'GT:Guatemala',
    'GU:Guam',
    'GW:Guinea-Bissau',
    'GY:Guyana',
    'HK:Hong Kong SAR China',
    'HM:Heard and McDonald Islands',
    'HN:Honduras',
    'HR:Croatia',
    'HT:Haiti',
    'HU:Hungary',
    'ID:Indonesia',
    'IE:Ireland',
    'IL:Israel',
    'IM:Isle of Man',
    'IN:India',
    'IO:British Indian Ocean Territory',
    'IQ:Iraq',
    'IR:Iran',
    'IS:Iceland',
    'IT:Italy',
    'JE:Jersey',
    'JM:Jamaica',
    'JO:Jordan',
    'JP:Japan',
    'KE:Kenya',
    'KG:Kyrgyzstan',
    'KH:Cambodia',
    'KI:Kiribati',
    'KM:Comoros',
    'KN:Saint Kitts and Nevis',
    'KP:North Korea',
    'KR:South Korea',
    'KW:Kuwait',
    'KY:Cayman Islands',
    'KZ:Kazakhstan',
    'LA:Laos',
    'LB:Lebanon',
    'LC:Saint Lucia',
    'LI:Liechtenstein',
    'LK:Sri Lanka',
    'LR:Liberia',
    'LS:Lesotho',
    'LT:Lithuania',
    'LU:Luxembourg',
    'LV:Latvia',
    'LY:Libya',
    'MA:Morocco',
    'MC:Monaco',
    'MD:Moldova',
    'ME:Montenegro',
    'MF:Saint Martin',
    'MG:Madagascar',
    'MH:Marshall Islands',
    'MK:North Macedonia',
    'ML:Mali',
    'MM:Myanmar (Burma)',
    'MN:Mongolia',
    'MO:Macao SAR China',
    'MP:Northern Mariana Islands',
    'MQ:Martinique',
    'MR:Mauritania',
    'MS:Montserrat',
    'MT:Malta',
    'MU:Mauritius',
    'MV:Maldives',
    'MW:Malawi',
    'MX:Mexico',
    'MY:Malaysia',
    'MZ:Mozambique',
    'NA:Namibia',
    'NC:New Caledonia',
    'NE:Niger',
    'NF:Norfolk Island',
    'NG:Nigeria',
    'NI:Nicaragua',
    'NL:Netherlands',
    'NO:Norway',
    'NP:Nepal',
    'NR:Nauru',
    'NU:Niue',
    'NZ:New Zealand',
    'OM:Oman',
    'PA:Panama',
    'PE:Peru',
    'PF:French Polynesia',
    'PG:Papua New Guinea',
    'PH:Philippines',
    'PK:Pakistan',
    'PL:Poland',
    'PM:Saint Pierre and Miquelon',
    'PN:Pitcairn Islands',
    'PR:Puerto Rico',
    'PS:Palestinian Territories',
    'PT:Portugal',
    'PW:Palau',
    'PY:Paraguay',
    'QA:Qatar',
    'RE:Réunion',
    'RO:Romania',
    'RS:Serbia',
    'RU:Russia',
    'RW:Rwanda',
    'SA:Saudi Arabia',
    'SB:Solomon Islands',
    'SC:Seychelles',
    'SD:Sudan',
    'SE:Sweden',
    'SG:Singapore',
    'SH:Saint Helena',
    'SI:Slovenia',
    'SJ:Svalbard and Jan Mayen',
    'SK:Slovakia',
    'SL:Sierra Leone',
    'SM:San Marino',
    'SN:Senegal',
    'SO:Somalia',
    'SR:Suriname',
    'SS:South Sudan',
    'ST:São Tomé and Príncipe',
    'SV:El Salvador',
    'SX:Sint Maarten',
    'SY:Syria',
    'SZ:Eswatini',
    'TC:Turks and Caicos Islands',
    'TD:Chad',
    'TF:French Southern Territories',
    'TG:Togo',
    'TH:Thailand',
    'TJ:Tajikistan',
    'TK:Tokelau',
    'TL:Timor-Leste',
    'TM:Turkmenistan',
    'TN:Tunisia',
    'TO:Tonga',
    'TR:Türkiye',
    'TT:Trinidad and Tobago',
    'TV:Tuvalu',
    'TW:Taiwan',
    'TZ:Tanzania',
    'UA:Ukraine',
    'UG:Uganda',
    'UM:U.S. Outlying Islands',
    'US:United States',
    'UY:Uruguay',
    'UZ:Uzbekistan',
    'VA:Vatican City',
    'VC:Saint Vincent and the Grenadines',
    'VE:Venezuela',
    'VG:British Virgin Islands',
    'VI:U.S. Virgin Islands',
    'VN:Vietnam',
    'VU:Vanuatu',
    'WF:Wallis and Futuna',
    'WS:Samoa',
    'YE:Yemen',
    'YT:Mayotte',
    'ZA:South Africa',
    'ZM:Zambia',
    'ZW:Zimbabwe',
  ];
}
