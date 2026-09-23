import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class SupplyItem {
  final String id;
  final String name;
  final String unit;
  final String category;
  final int inventoryQty;       // 管理端現有庫存
  final int totalRequestedQty;  // 所有受災者申請量總和
  final int totalPledgedQty;    // 所有民眾捐贈承諾量總和

  const SupplyItem({
    required this.id,
    required this.name,
    required this.unit,
    required this.category,
    this.inventoryQty = 0,
    this.totalRequestedQty = 0,
    this.totalPledgedQty = 0,
  });

  /// 仍需民眾捐贈量 = 申請量 - 庫存 - 已承諾捐贈，最小為 0
  int get netNeededQty =>
      (totalRequestedQty - inventoryQty - totalPledgedQty).clamp(0, 999999);

  /// 物資缺口供應進度 (庫存 + 已承諾) / 申請量
  double get fulfillProgress => totalRequestedQty == 0
      ? 0.0
      : ((inventoryQty + totalPledgedQty) / totalRequestedQty).clamp(0.0, 1.0);

  factory SupplyItem.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return SupplyItem(
      id: doc.id,
      name: d['name'] as String,
      unit: d['unit'] as String,
      category: d['category'] as String,
      inventoryQty: (d['inventoryQty'] as num? ?? 0).toInt(),
      totalRequestedQty: (d['totalRequestedQty'] as num? ?? 0).toInt(),
      totalPledgedQty: (d['totalPledgedQty'] as num? ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'unit': unit,
        'category': category,
        'inventoryQty': inventoryQty,
        'totalRequestedQty': totalRequestedQty,
        'totalPledgedQty': totalPledgedQty,
      };
}

const kSupplyCategories = ['全部', '食品飲水', '生活用品', '醫療衛生', '衣物'];

const kCategoryIcons = <String, IconData>{
  '食品飲水': Icons.water_drop_rounded,
  '生活用品': Icons.home_rounded,
  '醫療衛生': Icons.medical_services_rounded,
  '衣物': Icons.checkroom_rounded,
};

const kCategoryColors = <String, Color>{
  '食品飲水': Color(0xFF6B9EAD),
  '生活用品': Color(0xFF9B88B3),
  '醫療衛生': Color(0xFFC4553A),
  '衣物': Color(0xFFBF7A5A),
};

// 種子資料，含初始庫存量（管理端可於 Firebase Console 調整）
final kSeedItems = [
  const SupplyItem(id: 'water',        name: '礦泉水',      unit: '瓶', category: '食品飲水', inventoryQty: 100),
  const SupplyItem(id: 'canned',       name: '罐頭食品',    unit: '罐', category: '食品飲水', inventoryQty: 50),
  const SupplyItem(id: 'noodle',       name: '泡麵',        unit: '包', category: '食品飲水', inventoryQty: 80),
  const SupplyItem(id: 'biscuit',      name: '餅乾',        unit: '盒', category: '食品飲水', inventoryQty: 30),
  const SupplyItem(id: 'milk_powder',  name: '嬰兒奶粉',    unit: '罐', category: '食品飲水', inventoryQty: 10),
  const SupplyItem(id: 'blanket',      name: '毛毯',        unit: '條', category: '生活用品', inventoryQty: 40),
  const SupplyItem(id: 'sleeping_bag', name: '睡袋',        unit: '個', category: '生活用品', inventoryQty: 20),
  const SupplyItem(id: 'candle',       name: '蠟燭',        unit: '根', category: '生活用品', inventoryQty: 50),
  const SupplyItem(id: 'flashlight',   name: '手電筒',      unit: '個', category: '生活用品', inventoryQty: 15),
  const SupplyItem(id: 'battery',      name: '電池（3號）', unit: '組', category: '生活用品', inventoryQty: 30),
  const SupplyItem(id: 'mask',         name: '口罩',        unit: '片', category: '醫療衛生', inventoryQty: 200),
  const SupplyItem(id: 'antiseptic',   name: '消毒藥水',    unit: '瓶', category: '醫療衛生', inventoryQty: 10),
  const SupplyItem(id: 'bandage',      name: '繃帶',        unit: '卷', category: '醫療衛生', inventoryQty: 20),
  const SupplyItem(id: 'cold_med',     name: '感冒藥',      unit: '盒', category: '醫療衛生', inventoryQty: 15),
  const SupplyItem(id: 'fever_med',    name: '退燒藥',      unit: '盒', category: '醫療衛生', inventoryQty: 15),
  const SupplyItem(id: 'jacket',       name: '保暖外套',    unit: '件', category: '衣物',     inventoryQty: 20),
  const SupplyItem(id: 'raincoat',     name: '雨衣',        unit: '件', category: '衣物',     inventoryQty: 25),
  const SupplyItem(id: 'socks',        name: '棉襪',        unit: '雙', category: '衣物',     inventoryQty: 50),
];
