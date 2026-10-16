/// 個人資料欄位的驗證規則，註冊（`register_screen.dart`）與設定頁的個人資料編輯共用，
/// 兩邊的規則因此一定一致（#80）。每個 validator 都可以直接給 `TextFormField.validator`：
/// 通過時回傳 null，否則回傳要顯示的錯誤訊息。
abstract final class ProfileValidation {
  /// 電話欄位只能輸入的字元：數字與 `-`（給 `FilteringTextInputFormatter.allow`）。
  static final phoneCharacters = RegExp(r'[\d\-]');

  /// 可選的血型；未選為 null。
  static const bloodTypes = ['A 型', 'B 型', 'O 型', 'AB 型', '不清楚'];

  static String? name(String? value) => _required(value, '請輸入姓名');

  static String? phone(String? value) => _phone(value, '請輸入手機號碼', '手機號碼格式不正確');

  static String? area(String? value) => _required(value, '請輸入居住區域');

  static String? emergencyContactName(String? value) => _required(value, '請輸入聯絡人姓名');

  static String? emergencyContactPhone(String? value) => _phone(value, '請輸入聯絡人電話', '電話號碼格式不正確');

  static String? emergencyContactRelation(String? value) => _required(value, '請輸入與你的關係');

  static String? _required(String? value, String missing) =>
      (value == null || value.trim().isEmpty) ? missing : null;

  /// 至少 9 碼，`-` 不算。
  static String? _phone(String? value, String missing, String malformed) {
    if (value == null || value.trim().isEmpty) return missing;
    if (value.replaceAll('-', '').length < 9) return malformed;
    return null;
  }
}
