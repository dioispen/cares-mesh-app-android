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
          // 只提供型錄上的品項，不開放自行填寫物品名稱：管理端才能統一盤點與調度。
          child: items.isEmpty
              ? _emptyState()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final item = items[i];
                    return SupplyRequestCard(
                      item: item,
                      onRequest: (qty) => _submitRequest(item, qty),
                    );
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
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final item = _filteredItems[i];
                    return SupplyDonateCard(
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

// ── 申請物資 卡片 ────────────────────────────────────────────────
/// 申請物資卡片。公開只為了讓排版測試（#79）能單獨建立它；物資頁本身要連 Firestore。
@visibleForTesting
class SupplyRequestCard extends StatefulWidget {
  final SupplyItem item;
  final Future<void> Function(int qty) onRequest;

  /// 一開始就展開。物資頁一律收起；排版測試用它檢查展開後的內容放不放得下。
  final bool initiallyExpanded;

  const SupplyRequestCard({
    super.key,
    required this.item,
    required this.onRequest,
    this.initiallyExpanded = false,
  });

  @override
  State<SupplyRequestCard> createState() => _RequestCardState();
}

class _RequestCardState extends State<SupplyRequestCard> {
  static const _brown = Color(0xFF5C3D2E);
  static const _textSecondary = Color(0xFF8C7B6E);

  final _qtyCtrl = TextEditingController();
  bool _isSubmitting = false;
  late bool _expanded = widget.initiallyExpanded;

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
      if (mounted) setState(() => _expanded = false);
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

    return _SupplyCardShell(
      item: item,
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      expandLabel: '填寫申請數量',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(item.category,
                  style: TextStyle(fontSize: 12, color: catColor)),
              const Spacer(),
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
            const SizedBox(height: 6),
            Text(
              '已申請 ${item.totalRequestedQty} ${item.unit}，仍缺 ${item.netNeededQty} ${item.unit}',
              style: const TextStyle(fontSize: 12, color: _textSecondary),
            ),
          ],
          const SizedBox(height: 10),
          _QtyInputRow(
            controller: _qtyCtrl,
            hint: '申請數量',
            unit: item.unit,
            buttonLabel: '申請',
            buttonColor: _brown,
            submitting: _isSubmitting,
            onSubmit: _submit,
          ),
        ],
      ),
    );
  }
}

// ── 捐贈物資 卡片 ────────────────────────────────────────────────
/// 捐贈物資卡片。公開只為了讓排版測試（#79）能單獨建立它；物資頁本身要連 Firestore。
@visibleForTesting
class SupplyDonateCard extends StatefulWidget {
  final SupplyItem item;
  final Future<void> Function(int qty) onPledge;

  /// 一開始就展開。物資頁一律收起；排版測試用它檢查展開後的內容放不放得下。
  final bool initiallyExpanded;

  const SupplyDonateCard({
    super.key,
    required this.item,
    required this.onPledge,
    this.initiallyExpanded = false,
  });

  @override
  State<SupplyDonateCard> createState() => _DonateCardState();
}

class _DonateCardState extends State<SupplyDonateCard> {
  static const _textSecondary = Color(0xFF8C7B6E);

  final _qtyCtrl = TextEditingController();
  bool _isSubmitting = false;
  late bool _expanded = widget.initiallyExpanded;

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
      if (mounted) setState(() => _expanded = false);
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

  /// 四欄平分寬度；數量或單位太長（大字體、窄螢幕）時縮小字級，不超出卡片（#79）。
  Widget _stat(String label, String value, Color color) => Expanded(
        child: Column(
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(value,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color)),
            ),
            const SizedBox(height: 2),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  style: const TextStyle(
                      fontSize: 10, color: _textSecondary)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final catColor =
        kCategoryColors[item.category] ?? const Color(0xFF7AA67A);
    final progress = item.fulfillProgress;

    return _SupplyCardShell(
      item: item,
      expanded: _expanded,
      onToggle: () => setState(() => _expanded = !_expanded),
      expandLabel: '填寫捐贈數量',
      // 收起時仍看得到完成度，不必一張張點開才知道哪些最缺。
      trailing: Text(
        '${(progress * 100).toStringAsFixed(0)}%',
        style: TextStyle(
            fontSize: 13, fontWeight: FontWeight.w700, color: catColor),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
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
          _QtyInputRow(
            controller: _qtyCtrl,
            hint: '捐贈數量',
            unit: item.unit,
            buttonLabel: '承諾捐贈',
            buttonColor: catColor,
            submitting: _isSubmitting,
            onSubmit: _submit,
          ),
        ],
      ),
    );
  }
}

// ── 共用：可展開的物資卡片外框 ──────────────────────────────────
/// 收起時只有圖示、品名與右側的小展開按鈕，一個畫面看得到更多品項；
/// 點按鈕（或整列）才展開細節與數量欄位。
class _SupplyCardShell extends StatelessWidget {
  final SupplyItem item;
  final bool expanded;
  final VoidCallback onToggle;
  final String expandLabel;
  final Widget body;
  final Widget? trailing;

  const _SupplyCardShell({
    required this.item,
    required this.expanded,
    required this.onToggle,
    required this.expandLabel,
    required this.body,
    this.trailing,
  });

  static const _card = Color(0xFFFEFDF9);
  static const _brown = Color(0xFF5C3D2E);
  static const _textPrimary = Color(0xFF3D2C1E);

  @override
  Widget build(BuildContext context) {
    final catColor =
        kCategoryColors[item.category] ?? const Color(0xFF7AA67A);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: expanded ? catColor.withValues(alpha: 0.45) : Colors.transparent,
        ),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 8,
              offset: const Offset(0, 2))
        ],
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: catColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                        kCategoryIcons[item.category] ??
                            Icons.inventory_2_rounded,
                        color: catColor,
                        size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(item.name,
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: _textPrimary)),
                  ),
                  if (trailing != null) ...[
                    trailing!,
                    const SizedBox(width: 8),
                  ],
                  Semantics(
                    button: true,
                    label: expanded ? '收起' : expandLabel,
                    child: AnimatedRotation(
                      turns: expanded ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: _brown.withValues(alpha: 0.08),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.expand_more_rounded,
                            size: 20, color: _brown),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: expanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: body,
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// 數量輸入欄＋送出按鈕。
class _QtyInputRow extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final String unit;
  final String buttonLabel;
  final Color buttonColor;
  final bool submitting;
  final VoidCallback onSubmit;

  const _QtyInputRow({
    required this.controller,
    required this.hint,
    required this.unit,
    required this.buttonLabel,
    required this.buttonColor,
    required this.submitting,
    required this.onSubmit,
  });

  static const _brown = Color(0xFF5C3D2E);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              hintText: hint,
              suffixText: unit,
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
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 42,
          child: ElevatedButton(
            onPressed: submitting ? null : onSubmit,
            style: ElevatedButton.styleFrom(
              backgroundColor: buttonColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              disabledBackgroundColor: buttonColor.withValues(alpha: 0.5),
            ),
            child: submitting
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2))
                : Text(buttonLabel,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold)),
          ),
        ),
      ],
    );
  }
}
