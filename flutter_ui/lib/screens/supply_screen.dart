import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user.dart';
// ignore: library_prefixes
import '../models/supply items.dart';
// ignore: library_prefixes
import '../models/supply request.dart';
// ignore: library_prefixes
import '../models/supply pledge.dart';
import '../services/mascot_service.dart';

// ── 主畫面 ──────────────────────────────────────────────────────
class SupplyScreen extends StatefulWidget {
  const SupplyScreen({super.key});

  @override
  State<SupplyScreen> createState() => _SupplyScreenState();
}

class _SupplyScreenState extends State<SupplyScreen>
    with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFFF7F3EC);
  static const _card = Color(0xFFFEFDF9);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  late final TabController _tabController;
  String _selectedCategory = '全部';
  AppUser? _currentUser;
  List<SupplyItem> _items = [];
  bool _isLoading = true;
  bool _isOnline = true;

  StreamSubscription? _itemsSub;
  StreamSubscription? _connectSub;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    // 進入物資頁後隱藏小秘書（postFrame 避免 build 期間觸發 setState）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mascotOptionsNotifier.value = const [];
    });
    _loadUser();
    _initSupplyItems();
    _watchConnectivity();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _itemsSub?.cancel();
    _connectSub?.cancel();
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
    final snapshot = await col.limit(1).get();
    if (snapshot.docs.isEmpty) {
      final batch = FirebaseFirestore.instance.batch();
      for (final item in kSeedItems) {
        batch.set(col.doc(item.id), item.toMap());
      }
      await batch.commit();
    }
    _itemsSub = col.orderBy('category').snapshots().listen((snap) {
      if (!mounted) return;
      setState(() {
        _items = snap.docs.map(SupplyItem.fromDoc).toList();
        _isLoading = false;
      });
    });
  }

  Future<void> _watchConnectivity() async {
    final results = await Connectivity().checkConnectivity();
    if (mounted) {
      setState(() => _isOnline = results.any((r) => r != ConnectivityResult.none));
    }
    _connectSub = Connectivity().onConnectivityChanged.listen((results) {
      if (!mounted) return;
      setState(() => _isOnline = results.any((r) => r != ConnectivityResult.none));
    });
  }

  List<SupplyItem> get _filteredItems => _selectedCategory == '全部'
      ? _items
      : _items.where((s) => s.category == _selectedCategory).toList();

  Future<void> _submitRequest(SupplyItem item, int qty) async {
    if (_currentUser == null) return;
    final request = SupplyRequest(
      userId: _currentUser!.id,
      userName: _currentUser!.name,
      itemId: item.id,
      itemName: item.name,
      unit: item.unit,
      qty: qty,
    );
    final batch = FirebaseFirestore.instance.batch();
    batch.set(
      FirebaseFirestore.instance
          .collection('supply_requests')
          .doc(request.requestId),
      request.toMap(),
    );
    batch.update(
      FirebaseFirestore.instance.collection('supply_items').doc(item.id),
      {'totalRequestedQty': FieldValue.increment(qty)},
    );
    await batch.commit();
  }

  Future<void> _submitCustomRequest(
      String itemName, String unit, int qty) async {
    if (_currentUser == null) return;
    final request = SupplyRequest(
      userId: _currentUser!.id,
      userName: _currentUser!.name,
      itemId: 'custom',
      itemName: itemName,
      unit: unit.isEmpty ? '件' : unit,
      qty: qty,
    );
    await FirebaseFirestore.instance
        .collection('supply_requests')
        .doc(request.requestId)
        .set(request.toMap());
  }

  Future<void> _submitPledge(SupplyItem item, int qty) async {
    if (_currentUser == null) return;
    final pledge = SupplyPledge(
      userId: _currentUser!.id,
      userName: _currentUser!.name,
      itemId: item.id,
      itemName: item.name,
      unit: item.unit,
      qty: qty,
    );
    final batch = FirebaseFirestore.instance.batch();
    batch.set(
      FirebaseFirestore.instance
          .collection('supply_pledges')
          .doc(pledge.pledgeId),
      pledge.toMap(),
    );
    batch.update(
      FirebaseFirestore.instance.collection('supply_items').doc(item.id),
      {'totalPledgedQty': FieldValue.increment(qty)},
    );
    await batch.commit();
  }

  Widget _categoryFilter() => SizedBox(
        height: 52,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          itemCount: kSupplyCategories.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (_, i) {
            final cat = kSupplyCategories[i];
            final selected = cat == _selectedCategory;
            return GestureDetector(
              onTap: () => setState(() => _selectedCategory = cat),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: selected ? _brown : _card,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: selected ? _brown : _brown.withValues(alpha: 0.2),
                  ),
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
      );

  Widget _emptyState() => Center(
        child: Text('此分類暫無物資',
            style: TextStyle(color: _textSecondary, fontSize: 15)),
      );

  // ── Tab 1：申請物資 ──────────────────────────────────────────
  Widget _buildRequestTab() {
    final items = _filteredItems;
    return Column(
      children: [
        _categoryFilter(),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            itemCount: items.length + 1, // +1 for custom card
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, i) {
              if (i < items.length) {
                final item = items[i];
                return _RequestCard(
                  item: item,
                  onRequest: (qty) => _submitRequest(item, qty),
                );
              }
              return _CustomRequestCard(onSubmit: _submitCustomRequest);
            },
          ),
        ),
      ],
    );
  }

  // ── Tab 2：捐贈物資 ──────────────────────────────────────────
  Widget _buildDonateTab() {
    return Column(
      children: [
        if (!_isOnline)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            color: const Color(0xFFC4553A),
            child: const Text(
              '目前離線，顯示快取資料',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        _categoryFilter(),
        Expanded(
          child: _filteredItems.isEmpty
              ? _emptyState()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: _filteredItems.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final item = _filteredItems[i];
                    return _DonateCard(
                      item: item,
                      onPledge: (qty) => _submitPledge(item, qty),
                    );
                  },
                ),
        ),
      ],
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
          '物資管理',
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: _textPrimary),
        ),
        iconTheme: const IconThemeData(color: _textPrimary),
        bottom: TabBar(
          controller: _tabController,
          labelColor: _brown,
          unselectedLabelColor: _textSecondary,
          indicatorColor: _brown,
          tabs: const [
            Tab(
              text: '申請物資',
              icon: Icon(Icons.shopping_cart_outlined, size: 18),
            ),
            Tab(
              text: '捐贈物資',
              icon: Icon(Icons.volunteer_activism_outlined, size: 18),
            ),
          ],
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _brown))
          : TabBarView(
              controller: _tabController,
              children: [
                _buildRequestTab(),
                _buildDonateTab(),
              ],
            ),
    );
  }
}

// ── 自填需求 卡片 ────────────────────────────────────────────────
class _CustomRequestCard extends StatefulWidget {
  final Future<void> Function(String itemName, String unit, int qty) onSubmit;
  const _CustomRequestCard({required this.onSubmit});

  @override
  State<_CustomRequestCard> createState() => _CustomRequestCardState();
}

class _CustomRequestCardState extends State<_CustomRequestCard> {
  static const _card = Color(0xFFFEFDF9);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  final _nameCtrl = TextEditingController();
  final _unitCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _unitCtrl.dispose();
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final qty = int.tryParse(_qtyCtrl.text.trim());
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('請輸入物品名稱'), behavior: SnackBarBehavior.floating));
      return;
    }
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('請輸入有效數量'), behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      await widget.onSubmit(name, _unitCtrl.text.trim(), qty);
      _nameCtrl.clear();
      _unitCtrl.clear();
      _qtyCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('申請成功！'), behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('申請失敗：$e'), behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _brown.withValues(alpha: 0.35), width: 1.5),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2))
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
                  color: _brown.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.edit_note_rounded,
                    color: _brown, size: 20),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('其他需求',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: _textPrimary)),
                  Text('找不到品項？自行填寫申請',
                      style: TextStyle(fontSize: 12, color: _textSecondary)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              hintText: '物品名稱（例：輪椅、嬰兒車）',
              isDense: true,
              border:
                  OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: _brown, width: 2)),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _qtyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '數量',
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: _brown, width: 2)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _unitCtrl,
                  decoration: InputDecoration(
                    hintText: '單位（件）',
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: _brown, width: 2)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 42,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _brown,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    disabledBackgroundColor: _brown.withValues(alpha: 0.5),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('申請',
                          style: TextStyle(
                              fontSize: 14, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 申請物資 卡片 ────────────────────────────────────────────────
class _RequestCard extends StatefulWidget {
  final SupplyItem item;
  final Future<void> Function(int qty) onRequest;

  const _RequestCard({required this.item, required this.onRequest});

  @override
  State<_RequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<_RequestCard> {
  static const _card = Color(0xFFFEFDF9);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  final _qtyCtrl = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = int.tryParse(_qtyCtrl.text.trim());
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('請輸入有效數量'),
          behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      await widget.onRequest(qty);
      _qtyCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('申請成功！'),
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('申請失敗：$e'),
            behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final catColor =
        kCategoryColors[item.category] ?? const Color(0xFF7AA67A);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2))
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
                    kCategoryIcons[item.category] ??
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
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: catColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '庫存 ${item.inventoryQty} ${item.unit}',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: catColor),
                ),
              ),
            ],
          ),
          if (item.totalRequestedQty > 0) ...[
            const SizedBox(height: 8),
            Text(
              '已申請 ${item.totalRequestedQty} ${item.unit}，仍缺 ${item.netNeededQty} ${item.unit}',
              style:
                  const TextStyle(fontSize: 12, color: _textSecondary),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '申請數量',
                    suffixText: item.unit,
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: _brown, width: 2)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 42,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _brown,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    disabledBackgroundColor:
                        _brown.withValues(alpha: 0.5),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('申請',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── 捐贈物資 卡片 ────────────────────────────────────────────────
class _DonateCard extends StatefulWidget {
  final SupplyItem item;
  final Future<void> Function(int qty) onPledge;

  const _DonateCard({required this.item, required this.onPledge});

  @override
  State<_DonateCard> createState() => _DonateCardState();
}

class _DonateCardState extends State<_DonateCard> {
  static const _card = Color(0xFFFEFDF9);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);
  static const _textSecondary = Color(0xFF8C7B6E);

  final _qtyCtrl = TextEditingController();
  bool _isSubmitting = false;

  @override
  void dispose() {
    _qtyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = int.tryParse(_qtyCtrl.text.trim());
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('請輸入有效數量'),
          behavior: SnackBarBehavior.floating));
      return;
    }
    setState(() => _isSubmitting = true);
    try {
      await widget.onPledge(qty);
      _qtyCtrl.clear();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('感謝您的捐贈承諾！'),
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('操作失敗：$e'),
            behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Widget _stat(String label, String value, Color color) => Column(
        children: [
          Text(value,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: color)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                  fontSize: 10, color: _textSecondary)),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final catColor =
        kCategoryColors[item.category] ?? const Color(0xFF7AA67A);
    final progress = item.fulfillProgress;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 標題列
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: catColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                    kCategoryIcons[item.category] ??
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
              Text(
                '${(progress * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: catColor),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // 統計數字列：需求 / 庫存 / 已承諾 / 仍需
          Container(
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
            decoration: BoxDecoration(
              color: const Color(0xFFF7F3EC),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _stat('需求量',
                    '${item.totalRequestedQty} ${item.unit}',
                    _textSecondary),
                Container(width: 1, height: 28, color: Colors.grey[300]),
                _stat('庫存',
                    '${item.inventoryQty} ${item.unit}', catColor),
                Container(width: 1, height: 28, color: Colors.grey[300]),
                _stat('已承諾',
                    '${item.totalPledgedQty} ${item.unit}', catColor),
                Container(width: 1, height: 28, color: Colors.grey[300]),
                _stat(
                  '仍需',
                  '${item.netNeededQty} ${item.unit}',
                  item.netNeededQty > 0
                      ? const Color(0xFFC4553A)
                      : const Color(0xFF7AA67A),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),

          // 進度條
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: catColor.withValues(alpha: 0.15),
              valueColor: AlwaysStoppedAnimation<Color>(catColor),
            ),
          ),
          const SizedBox(height: 12),

          // 輸入列
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    hintText: '捐贈數量',
                    suffixText: item.unit,
                    isDense: true,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide:
                            const BorderSide(color: _brown, width: 2)),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 42,
                child: ElevatedButton(
                  onPressed: _isSubmitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: catColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                    disabledBackgroundColor:
                        catColor.withValues(alpha: 0.5),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('承諾捐贈',
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
