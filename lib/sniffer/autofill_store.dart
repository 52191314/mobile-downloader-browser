import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

class AutofillProfile {
  final String id;
  final String label;
  final String fullName;
  final String email;
  final String phone;
  final String addressLine1;
  final String addressLine2;
  final String city;
  final String state;
  final String postalCode;
  final String country;
  final String cardName;
  final String cardNumber;
  final String cardExpiry;
  final bool includeCard;

  const AutofillProfile({
    required this.id,
    required this.label,
    this.fullName = '',
    this.email = '',
    this.phone = '',
    this.addressLine1 = '',
    this.addressLine2 = '',
    this.city = '',
    this.state = '',
    this.postalCode = '',
    this.country = '',
    this.cardName = '',
    this.cardNumber = '',
    this.cardExpiry = '',
    this.includeCard = false,
  });

  bool get isEmpty =>
      fullName.isEmpty &&
      email.isEmpty &&
      phone.isEmpty &&
      addressLine1.isEmpty &&
      addressLine2.isEmpty &&
      city.isEmpty &&
      state.isEmpty &&
      postalCode.isEmpty &&
      country.isEmpty;

  AutofillProfile copyWith({
    String? label,
    String? fullName,
    String? email,
    String? phone,
    String? addressLine1,
    String? addressLine2,
    String? city,
    String? state,
    String? postalCode,
    String? country,
    String? cardName,
    String? cardNumber,
    String? cardExpiry,
    bool? includeCard,
  }) {
    return AutofillProfile(
      id: id,
      label: label ?? this.label,
      fullName: fullName ?? this.fullName,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      addressLine1: addressLine1 ?? this.addressLine1,
      addressLine2: addressLine2 ?? this.addressLine2,
      city: city ?? this.city,
      state: state ?? this.state,
      postalCode: postalCode ?? this.postalCode,
      country: country ?? this.country,
      cardName: cardName ?? this.cardName,
      cardNumber: cardNumber ?? this.cardNumber,
      cardExpiry: cardExpiry ?? this.cardExpiry,
      includeCard: includeCard ?? this.includeCard,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'fullName': fullName,
    'email': email,
    'phone': phone,
    'addressLine1': addressLine1,
    'addressLine2': addressLine2,
    'city': city,
    'state': state,
    'postalCode': postalCode,
    'country': country,
    'cardName': cardName,
    'cardNumber': cardNumber,
    'cardExpiry': cardExpiry,
    'includeCard': includeCard,
  };

  factory AutofillProfile.fromJson(Map<String, dynamic> json) {
    return AutofillProfile(
      id: json['id'] as String,
      label: json['label'] as String? ?? 'Profile',
      fullName: json['fullName'] as String? ?? '',
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String? ?? '',
      addressLine1: json['addressLine1'] as String? ?? '',
      addressLine2: json['addressLine2'] as String? ?? '',
      city: json['city'] as String? ?? '',
      state: json['state'] as String? ?? '',
      postalCode: json['postalCode'] as String? ?? '',
      country: json['country'] as String? ?? '',
      cardName: json['cardName'] as String? ?? '',
      cardNumber: json['cardNumber'] as String? ?? '',
      cardExpiry: json['cardExpiry'] as String? ?? '',
      includeCard: json['includeCard'] as bool? ?? false,
    );
  }
}

class AutofillStore {
  final String fileName;

  const AutofillStore({this.fileName = 'autofill_profiles.json'});

  Future<List<AutofillProfile>> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return const [];
      final list = decoded['profiles'] as List? ?? const [];
      return list
          .whereType<Map>()
          .map(
            (item) =>
                AutofillProfile.fromJson(Map<String, dynamic>.from(item)),
          )
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(List<AutofillProfile> profiles) async {
    try {
      final file = await _file();
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsString(
        jsonEncode({
          'profiles': profiles.map((p) => p.toJson()).toList(),
        }),
      );
    } catch (_) {}
  }

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }
}
