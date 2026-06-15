import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

class MascotOption {
  final String icon;
  final String label;
  final String response;
  const MascotOption({
    required this.icon,
    required this.label,
    required this.response,
  });
}

final RouteObserver<ModalRoute<void>> mascotRouteObserver =
    RouteObserver<ModalRoute<void>>();

// Always notifies listeners regardless of value equality,
// so the mascot renders correctly on initial push (not just pop-back).
class _MascotOptionsNotifier extends ChangeNotifier
    implements ValueListenable<List<MascotOption>> {
  _MascotOptionsNotifier(this._value);
  List<MascotOption> _value;

  @override
  List<MascotOption> get value => _value;

  set value(List<MascotOption> newValue) {
    _value = newValue;
    notifyListeners();
  }
}

final _MascotOptionsNotifier mascotOptionsNotifier =
    _MascotOptionsNotifier(const []);

// ─── Per-screen option sets ───────────────────────────────────────────────────

const homeOptions = [
  MascotOption(
    icon: '📋',
    label: '這個 APP 怎麼用？',
    response:
        '主畫面有 6 大功能 👇\n\n🆘 SOS 緊急求救\n📖 防災知識\n🗺️ 避難所地圖\n❤️ 健康回報\n💬 聊天室\n📦 物資捐贈\n\n點擊任一功能卡即可進入！',
  ),
  MascotOption(
    icon: '📦',
    label: '物資捐贈怎麼用？',
    response:
        '這裡顯示目前需要募集的物資清單 📋\n\n上方可依分類篩選物資：\n🥤 食品飲水　🏠 生活用品\n💊 醫療衛生　👔 衣物\n\n點擊任一物資卡片\n→ 輸入想捐贈的數量\n→ 點「確認認領」即完成登記 ✅\n\n感謝你的善心支持！',
  ),
  MascotOption(
    icon: '📧',
    label: '聯絡客服',
    response:
        '有任何問題或建議，歡迎聯絡我們 💙\n\n📧 客服信箱：\nhu_cares@gmail.com\n\n來信請附上：\n· 問題描述\n· 使用裝置型號\n· 發生時間\n\n我們會盡快回覆你！',
  ),
];

const knowledgeOptions = [
  MascotOption(
    icon: '📖',
    label: '這個頁面怎麼用？',
    response:
        '畫面裡有 7 顆漂浮泡泡 🫧\n每顆代表一個防災主題！\n\n👆 點擊任一泡泡\n→ 查看詳細的重點須知\n→ 觀看示範影片\n\n泡泡還會互相碰撞反彈，盡情探索吧！',
  ),
  MascotOption(
    icon: '🌀',
    label: '有哪些防災主題？',
    response:
        '這裡涵蓋 7 大防災主題 📚\n\n🌍 地震　🌀 颱風　🌊 洪水\n🔥 火災　🎒 緊急物資\n📞 緊急電話　🩺 急救知識\n\n點擊各泡泡即可查看詳細重點！',
  ),
  MascotOption(
    icon: '🩺',
    label: '緊急狀況怎麼急救？',
    response:
        '點擊「急救知識」泡泡可以查看詳細步驟 🩺\n\n包含：\n🫀 CPR＋AED 操作\n🩸 大量出血處理\n🔥 燒燙傷處置（沖脫泡蓋送）\n☣️ 毒化物質應對\n☢️ 核子事故停看聽\n\n影片示範也在裡面！',
  ),
];

const shelterOptions = [
  MascotOption(
    icon: '📍',
    label: '如何找最近的避難所？',
    response:
        '請先允許 APP 存取你的位置 📡\n地圖會自動將你的位置置中，\n並顯示附近所有的避難場所！\n\n藍色圖釘 = 避難所\n點擊圖釘可看詳細資訊 ℹ️',
  ),
  MascotOption(
    icon: '🗺️',
    label: '地圖怎麼使用？',
    response:
        '雙指縮放可調整地圖大小 🔍\n拖曳可移動地圖位置\n\n點擊左下角的定位按鈕 🎯\n可以快速回到你目前的位置！',
  ),
  MascotOption(
    icon: '🎒',
    label: '進避難所要帶什麼？',
    response:
        '建議攜帶「72小時避難包」\n\n💧 飲用水（每人每日 2L）\n🍱 乾糧與罐頭食品\n💊 常備藥物\n🔦 手電筒與備用電池\n📄 重要證件影本\n💰 少量現金\n\n詳見「防災知識 → 緊急物資」！',
  ),
];

const sosOptions = [
  MascotOption(
    icon: '🆘',
    label: '如何發送求救訊號？',
    response:
        '在此頁面輸入你的狀況與位置說明，\n然後點擊「發送 SOS」按鈕 📡\n\n系統會將你的 GPS 位置和訊息\n傳送給救援單位與你的緊急聯絡人！',
  ),
  MascotOption(
    icon: '📞',
    label: '緊急電話有哪些？',
    response:
        '台灣緊急聯絡電話：\n\n🚒 消防／救護 → 119\n👮 警察報案 → 110\n📞 災害應變中心 → 1991\n🏥 衛福部安心專線 → 1925\n\n請在緊急時立刻撥打！',
  ),
  MascotOption(
    icon: '✅',
    label: '什麼時候該按 SOS？',
    response:
        '以下情況請立刻使用 SOS：\n\n🔥 火災、爆炸、建築物倒塌\n🌊 洪水或土石流威脅\n🤕 有人受傷需要緊急救援\n🚨 遭受攻擊或生命威脅\n\n非緊急情況請撥 1991 詢問！',
  ),
];

const healthOptions = [
  MascotOption(
    icon: '💊',
    label: '健康回報怎麼填？',
    response:
        '請如實填寫你目前的身體狀況 💙\n\n包含：傷勢、症狀、用藥需求等\n系統會將資訊回報給醫療單位\n\n如有緊急傷勢，請同時撥打 119！',
  ),
  MascotOption(
    icon: '🏥',
    label: '受傷了怎麼辦？',
    response:
        '輕微傷：清潔傷口後包紮 🩹\n\n嚴重傷（大量出血、骨折）：\n→ 立刻撥打 119\n→ 保持傷者平躺\n→ 不要移動脊椎受傷者\n\n詳細急救方法見「防災知識 → 急救知識」！',
  ),
  MascotOption(
    icon: '📋',
    label: '回報資料誰會看到？',
    response:
        '你的健康回報資料會傳送給：\n\n🏥 醫療救援單位\n👨‍💼 災害應變中心管理人員\n\n資料僅用於緊急救援目的，\n不會用於其他商業用途 🔒',
  ),
];

const chatOptions = [
  MascotOption(
    icon: '💬',
    label: '聊天室怎麼使用？',
    response:
        '這裡是災民互助聯絡頻道 💙\n\n你可以：\n📢 發布求助或資訊\n👥 與附近的人互動\n📍 分享你的位置與狀況\n\n請保持禮貌，優先傳遞重要資訊！',
  ),
  MascotOption(
    icon: '🔒',
    label: '訊息安全嗎？',
    response:
        '聊天室使用 Mesh 網路傳輸 📡\n即使網路中斷也能透過藍牙\n與附近裝置進行通訊！\n\n請勿在聊天室分享個人隱私資訊\n（如身份證號、銀行帳號等）🔐',
  ),
  MascotOption(
    icon: '📡',
    label: '沒有網路也能用嗎？',
    response:
        '可以！這個聊天室支援\n藍牙 Mesh 網路 📶\n\n只要開啟手機藍牙，\n就能與附近 100 公尺內的裝置\n互相傳遞訊息，完全不需要 WiFi！',
  ),
];

const supplyOptions = [
  MascotOption(
    icon: '📦',
    label: '怎麼認領物資？',
    response:
        '瀏覽物資列表，找到你需要的項目 👀\n\n點擊「認領」按鈕，\n填寫你的聯絡方式和數量\n\n等待捐贈者確認後，\n依照指示前往取貨 ✅',
  ),
  MascotOption(
    icon: '🤝',
    label: '如何捐贈物資？',
    response:
        '點擊右上角的「＋」按鈕\n填寫物資名稱、數量、位置\n\n系統會將你的捐贈資訊\n發布給需要幫助的人 💙\n\n感謝你的善心！',
  ),
  MascotOption(
    icon: '🔍',
    label: '找不到需要的物資？',
    response:
        '可以在搜尋欄輸入物資名稱 🔎\n\n或是在聊天室發布求助訊息，\n讓附近的人知道你的需求！\n\n也可以撥打\n📞 1991 災害應變中心 詢問物資調配。',
  ),
];
