import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException, PlatformException;
import 'package:shared_preferences/shared_preferences.dart';
import '../bridge/bitchat_bridge.dart';
import '../protocol/supply_exchange_packet.dart';
import '../services/supply_delivery.dart';
import '../services/supply_exchange_feed.dart';
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
    _tabController = TabController(length: 3, vsync: this);
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
    // 型錄為空時寫入種子。離線、或讀取逾時就跳過：下面的監聽會先給本機快取，連上線再補。
    try {
      final snapshot = await col.limit(1).get().timeout(_cloudWriteTimeout);
      if (snapshot.docs.isEmpty) {
        final batch = FirebaseFirestore.instance.batch();
        for (final item in kSeedItems) {
          batch.set(col.doc(item.id), item.toMap());
        }
        await batch.commit().timeout(_cloudWriteTimeout);
      }
    } catch (e) {
      debugPrint('supply_items seed check skipped: $e');
    }
    _itemsSub = col.orderBy('category').snapshots().listen(
      (snap) {
        if (!mounted) return;
        setState(() {
          _items = snap.docs.map(SupplyItem.fromDoc).toList();
          _isLoading = false;
        });
      },
      onError: (Object e) {
        debugPrint('supply_items listen failed: $e');
        if (mounted) setState(() => _isLoading = false);
      },
    );
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

  /// 一次送出走兩條路：經 BLE mesh 廣播給附近裝置（有網路的人會代傳到後台），以及寫進雲端
  /// 自己的 `supply_requests`／`supply_pledges`。兩條路各自獨立，任一條失敗不拖垮另一條；
  /// 斷網是災害現場的常態，雲端寫入離線時進本機佇列、不等伺服器確認，畫面不能卡住。
  Future<void> _submitRequest(SupplyItem item, int qty) async {
    final user = _requireUser();
    final request = SupplyRequest(
      userId: user.id,
      userName: user.name,
      itemId: item.id,
      itemName: item.name,
      unit: item.unit,
      qty: qty,
    );
    final delivery = await _deliver(
      action: 'request',
      exchangeId: SupplyExchangePacket.exchangeIdFromUuid(request.requestId),
      item: item,
      qty: qty,
      cloudWrite: (batch) {
        batch.set(
          FirebaseFirestore.instance.collection('supply_requests').doc(request.requestId),
          request.toMap(),
        );
        batch.update(
          FirebaseFirestore.instance.collection('supply_items').doc(item.id),
          {'totalRequestedQty': FieldValue.increment(qty)},
        );
      },
    );
    _showSubmissionResult(delivery, success: '已送出申請');
  }

  Future<void> _submitPledge(SupplyItem item, int qty) async {
    final user = _requireUser();
    final pledge = SupplyPledge(
      userId: user.id,
      userName: user.name,
      itemId: item.id,
      itemName: item.name,
      unit: item.unit,
      qty: qty,
    );
    final delivery = await _deliver(
      action: 'offer',
      exchangeId: SupplyExchangePacket.exchangeIdFromUuid(pledge.pledgeId),
      item: item,
      qty: qty,
      cloudWrite: (batch) {
        batch.set(
          FirebaseFirestore.instance.collection('supply_pledges').doc(pledge.pledgeId),
          pledge.toMap(),
        );
        batch.update(
          FirebaseFirestore.instance.collection('supply_items').doc(item.id),
          {'totalPledgedQty': FieldValue.increment(qty)},
        );
      },
    );
    _showSubmissionResult(delivery, success: '感謝您的捐贈承諾');
  }

  /// 本機沒有 app_user（登入時讀不到 users 文件）就不送：送出去的紀錄會沒有人名，後台對不上。
  AppUser _requireUser() {
    final user = _currentUser;
    if (user == null) throw const _NotSignedIn();
    return user;
  }

  Future<SupplyDelivery> _deliver({
    required String action,
    required String exchangeId,
    required SupplyItem item,
    required int qty,
    required void Function(WriteBatch batch) cloudWrite,
  }) async {
    String? broadcastFailure;
    try {
      await BitchatBridge.sendSupplyExchange(
        action: action,
        exchangeId: exchangeId,
        itemId: item.id,
        itemName: item.name,
        quantity: qty,
        unit: item.unit,
      );
    } on PlatformException catch (e) {
      broadcastFailure = switch (e.code) {
        'SERVICE_NOT_READY' => '藍牙 Mesh 尚未啟動',
        'INVALID_FORMAT' => '封包格式不合法',
        _ => e.message ?? e.code,
      };
    } on MissingPluginException {
      broadcastFailure = '此裝置沒有藍牙 Mesh';
    } catch (e) {
      broadcastFailure = '$e';
    }

    String? uploadFailure;
    var uploadQueued = false;
    final batch = FirebaseFirestore.instance.batch();
    cloudWrite(batch);
    try {
      // Firestore 的寫入要等伺服器確認才完成，離線時永遠不會完成（資料已進本機佇列，恢復連線
      // 後會自動送出）。等一小段時間就放手，不讓畫面卡在轉圈。
      await batch.commit().timeout(_cloudWriteTimeout);
    } on TimeoutException {
      uploadQueued = true;
    } on FirebaseException catch (e) {
      uploadFailure = e.code == 'permission-denied' ? '雲端拒絕寫入（請確認已登入）' : (e.message ?? e.code);
    } catch (e) {
      uploadFailure = '$e';
    }
    return SupplyDelivery(
      broadcastFailure: broadcastFailure,
      uploadFailure: uploadFailure,
      uploadQueued: uploadQueued,
    );
  }

  static const _cloudWriteTimeout = Duration(seconds: 8);

  void _showSubmissionResult(SupplyDelivery delivery, {required String success}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(delivery.message(success)),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: delivery.failed ? 6 : 4),
      ),
    );
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

  // ── Tab 3：附近與我的 ────────────────────────────────────────
  /// 上半是附近裝置經 BLE mesh 送來的需求／捐贈（離線也看得到，來源是 [SupplyExchangeFeed]）；
  /// 下半是自己寫進雲端的申請與捐贈紀錄（`supply_requests`／`supply_pledges`，規則只讓本人讀，
  /// 離線時顯示 Firestore 的本機快取）。
  Widget _buildActivityTab() {
    final uid = _currentUser?.id;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        _sectionTitle('附近的需求與捐贈', Icons.bluetooth_searching),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            '經藍牙 Mesh 從附近裝置收到，不需要網路。只有物資與數量，沒有對方的姓名。',
            style: TextStyle(fontSize: 12, color: _textSecondary),
          ),
        ),
        ListenableBuilder(
          listenable: SupplyExchangeFeed.instance,
          builder: (context, _) {
            final entries = SupplyExchangeFeed.instance.entries;
            if (entries.isEmpty) return _emptyNote('目前沒有收到附近的物資需求或捐贈。');
            return Column(
              children: [
                for (final e in entries)
                  _ActivityTile(
                    isRequest: e.isRequest,
                    itemName: e.packet.itemName,
                    quantity: e.packet.quantity,
                    unit: e.packet.unit,
                    subtitle: '附近裝置 ${e.senderPeerId.length >= 8 ? e.senderPeerId.substring(0, 8) : e.senderPeerId} · ${_relativeTime(e.createdAt)}',
                    status: null,
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 20),
        _sectionTitle('我的申請', Icons.shopping_cart_outlined),
        if (uid == null)
          _emptyNote('讀不到你的帳號資料，無法顯示你的紀錄。')
        else
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('supply_requests')
                .where('userId', isEqualTo: uid)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return _emptyNote('讀取失敗：${snap.error}');
              if (!snap.hasData) return _emptyNote('載入中…');
              final docs = snap.data!.docs.map(SupplyRequest.fromDoc).toList()
                ..sort((a, b) => (b.createdAt ?? DateTime(0)).compareTo(a.createdAt ?? DateTime(0)));
              if (docs.isEmpty) return _emptyNote('你還沒有申請過物資。');
              return Column(
                children: [
                  for (final r in docs)
                    _ActivityTile(
                      isRequest: true,
                      itemName: r.itemName,
                      quantity: r.qty,
                      unit: r.unit,
                      subtitle: r.createdAt == null ? '尚未同步到雲端' : _relativeTime(r.createdAt!),
                      status: _requestStatusLabel(r.status),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 20),
        _sectionTitle('我的捐贈', Icons.volunteer_activism_outlined),
        if (uid == null)
          const SizedBox.shrink()
        else
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('supply_pledges')
                .where('userId', isEqualTo: uid)
                .snapshots(),
            builder: (context, snap) {
              if (snap.hasError) return _emptyNote('讀取失敗：${snap.error}');
              if (!snap.hasData) return _emptyNote('載入中…');
              final docs = snap.data!.docs.map(SupplyPledge.fromDoc).toList()
                ..sort((a, b) => (b.pledgedAt ?? DateTime(0)).compareTo(a.pledgedAt ?? DateTime(0)));
              if (docs.isEmpty) return _emptyNote('你還沒有登記過捐贈。');
              return Column(
                children: [
                  for (final p in docs)
                    _ActivityTile(
                      isRequest: false,
                      itemName: p.itemName,
                      quantity: p.qty,
                      unit: p.unit,
                      subtitle: p.pledgedAt == null ? '尚未同步到雲端' : _relativeTime(p.pledgedAt!),
                      status: _pledgeStatusLabel(p.status),
                    ),
                ],
              );
            },
          ),
      ],
    );
  }

  Widget _sectionTitle(String title, IconData icon) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Icon(icon, size: 18, color: _brown),
            const SizedBox(width: 6),
            Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: _textPrimary)),
          ],
        ),
      );

  Widget _emptyNote(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(text, style: const TextStyle(fontSize: 13, color: _textSecondary)),
      );

  static String _requestStatusLabel(String status) => switch (status) {
        'fulfilled' => '已滿足',
        'cancelled' => '已取消',
        _ => '等待中',
      };

  static String _pledgeStatusLabel(String status) => switch (status) {
        'delivered' => '已送達',
        'cancelled' => '已取消',
        _ => '已承諾',
      };

  static String _relativeTime(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '剛剛';
    if (d.inMinutes < 60) return '${d.inMinutes} 分鐘前';
    if (d.inHours < 24) return '${d.inHours} 小時前';
    return '${d.inDays} 天前';
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
            Tab(
              text: '附近與我的',
              icon: Icon(Icons.bluetooth_searching, size: 18),
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
                _buildActivityTab(),
              ],
            ),
    );
  }
}

/// 卡片把例外原樣顯示在「申請失敗：…」後面，所以 toString 就是給使用者看的句子。
class _NotSignedIn implements Exception {
  const _NotSignedIn();

  @override
  String toString() => '讀不到你的帳號資料，請重新登入後再試';
}

// ── 附近與我的：一列紀錄 ────────────────────────────────────────
class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.isRequest,
    required this.itemName,
    required this.quantity,
    required this.unit,
    required this.subtitle,
    required this.status,
  });

  final bool isRequest;
  final String itemName;
  final int quantity;
  final String unit;
  final String subtitle;

  /// 雲端紀錄的狀態；附近的 mesh 封包沒有狀態（null）。
  final String? status;

  @override
  Widget build(BuildContext context) {
    final color = isRequest ? const Color(0xFFC4553A) : const Color(0xFF6B9EAD);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFEFDF9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(isRequest ? Icons.shopping_cart_outlined : Icons.volunteer_activism_outlined, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${isRequest ? '需要' : '捐贈'} $itemName $quantity $unit',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF3D2C1E)),
                ),
                const SizedBox(height: 2),
                Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF8C7B6E))),
              ],
            ),
          ),
          if (status != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(status!, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
            ),
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
