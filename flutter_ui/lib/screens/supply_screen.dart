import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';

// ── 物資資料模型 ────────────────────────────────────────────────
class _SupplyItem {
  final String id;
  final String name;
  final String unit;
  final String category;
  final int neededQty;
  final int pledgedQty;

  const _SupplyItem({
    required this.id,
    required this.name,
    required this.unit,
    required this.category,
    required this.neededQty,
    this.pledgedQty = 0,
  });

  factory _SupplyItem.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return _SupplyItem(
      id: doc.id,
      name: d['name'] as String,
      unit: d['unit'] as String,
      category: d['category'] as String,
      neededQty: (d['neededQty'] as num).toInt(),
      pledgedQty: (d['pledgedQty'] as num? ?? 0).toInt(),
    );
  }

  Map<String, dynamic> toMap() => {
        'name': name,
        'unit': unit,
        'category': category,
        'neededQty': neededQty,
        'pledgedQty': pledgedQty,
      };
}

// 預設種子資料（首次建立時寫入 Firestore）
final _seedItems = [
  _SupplyItem(id: 'water',        name: '礦泉水',      unit: '瓶', category: '食品飲水', neededQty: 500),
  _SupplyItem(id: 'canned',       name: '罐頭食品',    unit: '罐', category: '食品飲水', neededQty: 300),
  _SupplyItem(id: 'noodle',       name: '泡麵',        unit: '包', category: '食品飲水', neededQty: 400),
  _SupplyItem(id: 'biscuit',      name: '餅乾',        unit: '盒', category: '食品飲水', neededQty: 200),
  _SupplyItem(id: 'milk_powder',  name: '嬰兒奶粉',    unit: '罐', category: '食品飲水', neededQty: 80),
  _SupplyItem(id: 'blanket',      name: '毛毯',        unit: '條', category: '生活用品', neededQty: 150),
  _SupplyItem(id: 'sleeping_bag', name: '睡袋',        unit: '個', category: '生活用品', neededQty: 100),
  _SupplyItem(id: 'candle',       name: '蠟燭',        unit: '根', category: '生活用品', neededQty: 200),
  _SupplyItem(id: 'flashlight',   name: '手電筒',      unit: '個', category: '生活用品', neededQty: 80),
  _SupplyItem(id: 'battery',      name: '電池（3號）', unit: '組', category: '生活用品', neededQty: 150),
  _SupplyItem(id: 'mask',         name: '口罩',        unit: '片', category: '醫療衛生', neededQty: 1000),
  _SupplyItem(id: 'antiseptic',   name: '消毒藥水',    unit: '瓶', category: '醫療衛生', neededQty: 60),
  _SupplyItem(id: 'bandage',      name: '繃帶',        unit: '卷', category: '醫療衛生', neededQty: 100),
  _SupplyItem(id: 'cold_med',     name: '感冒藥',      unit: '盒', category: '醫療衛生', neededQty: 80),
  _SupplyItem(id: 'fever_med',    name: '退燒藥',      unit: '盒', category: '醫療衛生', neededQty: 80),
  _SupplyItem(id: 'jacket',       name: '保暖外套',    unit: '件', category: '衣物',     neededQty: 100),
  _SupplyItem(id: 'raincoat',     name: '雨衣',        unit: '件', category: '衣物',     neededQty: 120),
  _SupplyItem(id: 'socks',        name: '棉襪',        unit: '雙', category: '衣物',     neededQty: 200),
];

const _categories = ['全部', '食品飲水', '生活用品', '醫療衛生', '衣物'];

const _categoryIcons = {
  '食品飲水': Icons.water_drop_rounded,
  '生活用品': Icons.home_rounded,
  '醫療衛生': Icons.medical_services_rounded,
  '衣物':    Icons.checkroom_rounded,
};

const _categoryColors = {
  '食品飲水': Color(0xFF6B9EAD),
  '生活用品': Color(0xFF9B88B3),
  '醫療衛生': Color(0xFFC4553A),
  '衣物':    Color(0xFFBF7A5A),
};

// ── 主畫面 ──────────────────────────────────────────────────────
class SupplyScreen extends StatefulWidget {
  const SupplyScreen({super.key});

  @override
  State<SupplyScreen> createState() => _SupplyScreenState();
}

class _SupplyScreenState extends State<SupplyScreen> {
  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  String _selectedCategory = '全部';
  AppUser? _currentUser;

  List<_SupplyItem> _items = [];
  bool _isLoading = true;

  // itemId → 本人認領資料（用於顯示 badge 與更新認領）
  Map<String, Map<String, dynamic>> _myPledges = {};

  StreamSubscription? _itemsSub;
  StreamSubscription? _myPledgesSub;

  @override
  void initState() {
    super.initState();
    _loadUser().then((_) {
      _initSupplyItems();
      _listenPledges();
    });
  }

  @override
  void dispose() {
    _itemsSub?.cancel();
    _myPledgesSub?.cancel();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('app_user');
    if (raw != null && mounted) {
      setState(() => _currentUser = AppUser.fromJson(jsonDecode(raw)));
    }
  }

  Future<void> _initSupplyItems() async {
    final col = FirebaseFirestore.instance.collection('supply_items');

    // 若 collection 是空的，先寫入種子資料
    final snapshot = await col.limit(1).get();
    if (snapshot.docs.isEmpty) {
      final batch = FirebaseFirestore.instance.batch();
      for (final item in _seedItems) {
        batch.set(col.doc(item.id), item.toMap());
      }
      await batch.commit();
    }

    // 即時監聽
    _itemsSub = col.orderBy('category').snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _items = snap.docs.map(_SupplyItem.fromDoc).toList();
        _isLoading = false;
      });
    });
  }

  void _listenPledges() {
    // 監聽本人認領
    if (_currentUser == null) return;
    _myPledgesSub = FirebaseFirestore.instance
        .collection('pledges')
        .where('userId', isEqualTo: _currentUser!.id)
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      final mine = <String, Map<String, dynamic>>{};
      for (final doc in snap.docs) {
        final d = doc.data();
        mine[d['itemId'] as String] = {
          'qty': (d['quantity'] as num?)?.toInt() ?? 0,
          'status': d['status'] ?? 'pledged',
          'pledgeId': doc.id,
        };
      }
      setState(() => _myPledges = mine);
    });
  }

  List<_SupplyItem> get _filteredItems => _selectedCategory == '全部'
      ? _items
      : _items.where((s) => s.category == _selectedCategory).toList();

  void _showPledgeSheet(_SupplyItem item) {
    if (_currentUser == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PledgeSheet(
        item: item,
        currentUser: _currentUser!,
        pledgedTotal: item.pledgedQty,
        myPledge: _myPledges[item.id],
        onPledge: (qty) async {
          final existing = _myPledges[item.id];
          final itemRef = FirebaseFirestore.instance
              .collection('supply_items')
              .doc(item.id);

          if (existing != null) {
            final oldQty = existing['qty'] as int;
            final diff = qty - oldQty;
            await Future.wait([
              FirebaseFirestore.instance
                  .collection('pledges')
                  .doc(existing['pledgeId'] as String)
                  .update({
                'quantity': qty,
                'updatedAt': FieldValue.serverTimestamp(),
              }),
              // 同步更新 supply_items 的已認領總量
              itemRef.update({
                'pledgedQty': FieldValue.increment(diff),
              }),
            ]);
          } else {
            await Future.wait([
              FirebaseFirestore.instance.collection('pledges').add({
                'userId': _currentUser!.id,
                'userName': _currentUser!.name,
                'itemId': item.id,
                'itemName': item.name,
                'unit': item.unit,
                'quantity': qty,
                'status': 'pledged',
                'pledgedAt': FieldValue.serverTimestamp(),
              }),
              // 同步更新 supply_items 的已認領總量
              itemRef.update({
                'pledgedQty': FieldValue.increment(qty),
              }),
            ]);
          }
        },
      ),
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text(
          '物資捐贈',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _textPrimary),
        ),
        iconTheme: const IconThemeData(color: _textPrimary),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _brown))
          : _buildSupplyList(),
    );
  }

  // ── 需求物資 Tab ─────────────────────────────────────────────
  Widget _buildSupplyList() {
    return Column(
      children: [
        // 分類篩選
        SizedBox(
          height: 52,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            itemCount: _categories.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, i) {
              final cat = _categories[i];
              final selected = cat == _selectedCategory;
              return GestureDetector(
                onTap: () => setState(() => _selectedCategory = cat),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                  decoration: BoxDecoration(
                    color: selected ? _brown : _card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: selected ? _brown : _brown.withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    cat,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : _textSecondary,
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // 物資列表
        Expanded(
          child: _filteredItems.isEmpty
              ? Center(
                  child: Text('此分類暫無物資',
                      style: TextStyle(color: _textSecondary)))
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: _filteredItems.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final item = _filteredItems[i];
                    final pledged = item.pledgedQty;
                    final progress = (pledged / item.neededQty).clamp(0.0, 1.0);
                    final catColor = _categoryColors[item.category] ?? const Color(0xFF7AA67A);
                    final isMine = _myPledges.containsKey(item.id);

                    return GestureDetector(
                      onTap: () => _showPledgeSheet(item),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: _card,
                          borderRadius: BorderRadius.circular(16),
                          border: isMine
                              ? Border.all(color: catColor.withValues(alpha: 0.6), width: 1.5)
                              : null,
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.04),
                                blurRadius: 8,
                                offset: const Offset(0, 2)),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: catColor.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                      _categoryIcons[item.category] ??
                                          Icons.inventory_2_rounded,
                                      color: catColor,
                                      size: 20),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(item.name,
                                          style: const TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w700,
                                              color: _textPrimary)),
                                      Text(item.category,
                                          style: TextStyle(fontSize: 12, color: catColor)),
                                    ],
                                  ),
                                ),
                                if (isMine)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: catColor.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                        '已認領 ${_myPledges[item.id]!['qty']}${item.unit}',
                                        style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: catColor)),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                    '已認領 $pledged / 需要 ${item.neededQty} ${item.unit}',
                                    style: const TextStyle(
                                        fontSize: 12, color: _textSecondary)),
                                Text('${(progress * 100).toStringAsFixed(0)}%',
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: catColor)),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(4),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 6,
                                backgroundColor: catColor.withValues(alpha: 0.15),
                                valueColor: AlwaysStoppedAnimation<Color>(catColor),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

}

// ── 認領 BottomSheet ──────────────────────────────────────────
class _PledgeSheet extends StatefulWidget {
  final _SupplyItem item;
  final AppUser currentUser;
  final int pledgedTotal;
  final Map<String, dynamic>? myPledge;
  final Future<void> Function(int qty) onPledge;

  const _PledgeSheet({
    required this.item,
    required this.currentUser,
    required this.pledgedTotal,
    required this.myPledge,
    required this.onPledge,
  });

  @override
  State<_PledgeSheet> createState() => _PledgeSheetState();
}

class _PledgeSheetState extends State<_PledgeSheet> {
  static const _brown = Color(0xFF5C3D2E);
  static const _bg = Color(0xFFF7F3EC);
  static const _textSecondary = Color(0xFF8C7B6E);

  final _qtyCtrl = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    if (widget.myPledge != null) {
      _qtyCtrl.text = widget.myPledge!['qty'].toString();
    }
  }

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = int.tryParse(_qtyCtrl.text.trim());
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('請輸入有效數量'),
            behavior: SnackBarBehavior.floating),
      );
      return;
    }
    setState(() => _isLoading = true);
    try {
      await widget.onPledge(qty);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('操作失敗：$e'),
              behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catColor = _categoryColors[widget.item.category] ?? _brown;
    final remaining = widget.item.neededQty - widget.pledgedTotal;
    final isEditing = widget.myPledge != null;

    return Container(
      padding: EdgeInsets.fromLTRB(
          24, 16, 24, MediaQuery.of(context).viewInsets.bottom + 32),
      decoration: const BoxDecoration(
        color: Color(0xFFFEFDF9),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: catColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                    _categoryIcons[widget.item.category] ??
                        Icons.inventory_2_rounded,
                    color: catColor,
                    size: 24),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.item.name,
                      style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF3D2C1E))),
                  Text(widget.item.category,
                      style: TextStyle(fontSize: 13, color: catColor)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
                color: _bg, borderRadius: BorderRadius.circular(12)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _statItem('需要', '${widget.item.neededQty} ${widget.item.unit}', catColor),
                Container(width: 1, height: 32, color: Colors.grey[300]),
                _statItem('已認領', '${widget.pledgedTotal} ${widget.item.unit}', catColor),
                Container(width: 1, height: 32, color: Colors.grey[300]),
                _statItem(
                    '尚缺',
                    '${remaining.clamp(0, widget.item.neededQty)} ${widget.item.unit}',
                    remaining > 0
                        ? const Color(0xFFC4553A)
                        : const Color(0xFF7AA67A)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(isEditing ? '修改認領數量' : '我想捐贈',
              style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF3D2C1E))),
          const SizedBox(height: 8),
          TextField(
            controller: _qtyCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: '數量',
              suffixText: widget.item.unit,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: _brown, width: 2)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _isLoading ? null : _submit,
            style: ElevatedButton.styleFrom(
              backgroundColor: _brown,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 15),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              disabledBackgroundColor: _brown.withValues(alpha: 0.5),
            ),
            child: _isLoading
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Text(isEditing ? '更新認領' : '確認認領',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          if (isEditing) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消',
                  style: TextStyle(color: _textSecondary, fontSize: 14)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _statItem(String label, String value, Color color) {
    return Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        const SizedBox(height: 2),
        Text(label,
            style: const TextStyle(fontSize: 11, color: _textSecondary)),
      ],
    );
  }
}
