class UserModel {
  final String uid;    // Firebase Auth UID（全域唯一，由 Firebase 管理）
  final String? email;

  UserModel({required this.uid, this.email});

  // 從 Firebase User 轉換
  factory UserModel.fromFirebase(dynamic user) {
    return UserModel(
      uid: user.uid,
      email: user.email,
    );
  }
}
