import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_ui/models/profile_validation.dart';

void main() {
  group('required text fields', () {
    final fields = {
      '姓名': ProfileValidation.name,
      '居住區域': ProfileValidation.area,
      '聯絡人姓名': ProfileValidation.emergencyContactName,
      '與你的關係': ProfileValidation.emergencyContactRelation,
    };

    for (final MapEntry(key: label, value: validate) in fields.entries) {
      test('$label refuses empty or blank text and accepts anything else', () {
        expect(validate(null), isNotNull);
        expect(validate(''), isNotNull);
        expect(validate('   '), isNotNull);
        expect(validate('王小明'), isNull);
      });
    }

    test('say which field is missing, as registration does', () {
      expect(ProfileValidation.name(''), '請輸入姓名');
      expect(ProfileValidation.area(''), '請輸入居住區域');
      expect(ProfileValidation.emergencyContactName(''), '請輸入聯絡人姓名');
      expect(ProfileValidation.emergencyContactRelation(''), '請輸入與你的關係');
    });
  });

  group('phone numbers', () {
    test('are required', () {
      expect(ProfileValidation.phone(''), '請輸入手機號碼');
      expect(ProfileValidation.emergencyContactPhone(' '), '請輸入聯絡人電話');
    });

    test('need at least nine digits, dashes not counted', () {
      expect(ProfileValidation.phone('0912-345-6'), '手機號碼格式不正確');
      expect(ProfileValidation.phone('0912-345-678'), isNull);
      expect(ProfileValidation.emergencyContactPhone('04-1234-56'), '電話號碼格式不正確');
      expect(ProfileValidation.emergencyContactPhone('049-1234567'), isNull);
    });

    test('take digits and dashes only', () {
      expect(ProfileValidation.phoneCharacters.hasMatch('5'), isTrue);
      expect(ProfileValidation.phoneCharacters.hasMatch('-'), isTrue);
      expect(ProfileValidation.phoneCharacters.hasMatch('+'), isFalse);
      expect(ProfileValidation.phoneCharacters.hasMatch('a'), isFalse);
    });
  });

  test('blood types are the ones registration offers', () {
    expect(ProfileValidation.bloodTypes, ['A 型', 'B 型', 'O 型', 'AB 型', '不清楚']);
  });
}
