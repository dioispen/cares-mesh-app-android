import 'package:firebase_auth/firebase_auth.dart';
import '../models/user_model.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // 建立使用者模型
  UserModel? _userFromFirebaseUser(User? user) {
    return user != null ? UserModel.fromFirebase(user) : null;
  }

  // 監聽驗證狀態
  Stream<UserModel?> get user {
    return _auth.authStateChanges().map(_userFromFirebaseUser);
  }

  // 註冊：Email & 密碼
  Future<UserModel?> registerWithEmailAndPassword(String email, String password) async {
    try {
      UserCredential result = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      return _userFromFirebaseUser(result.user);
    } on FirebaseAuthException catch (e) {
      print('Firebase Auth Error: ${e.code}');
      rethrow; // 讓 UI 層能捕獲具體錯誤
    } catch (e) {
      print('Register Error: $e');
      return null;
    }
  }

  // 登入：Email & 密碼
  Future<UserModel?> signInWithEmailAndPassword(String email, String password) async {
    try {
      UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      return _userFromFirebaseUser(result.user);
    } catch (e) {
      print(e.toString());
      return null;
    }
  }

  // 登出
  Future<void> signOut() async {
    try {
      return await _auth.signOut();
    } catch (e) {
      print(e.toString());
    }
  }

  // 獲取當前用戶 UID
  String? get currentUid => _auth.currentUser?.uid;
}
