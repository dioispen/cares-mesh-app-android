import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../bridge/bitchat_bridge.dart';
import '../models/experiment_status.dart';

/// 現場即時計數畫面（#70 §3）：實機量測時在現場看 run 是否有效，不必拉 log。
///
/// **只在 debug build 存在。** 唯一的入口是首頁標頭盾牌圖示的長按，且只在 `kDebugMode` 下才建出
/// 那個入口；release build 沒有任何地方引用這個畫面，編譯時整個被 tree-shake 掉（原生的
/// `ExperimentBridge` 也只在 debug source set）。不要從其他地方開啟它，`bridge_contract_test.dart`
/// 會檢查。
///
/// 畫面有三塊：本機狀態（目前直連數、電源模式、本機 peerId）、實驗用自動發送器（參數表單、
/// 開始／停止、已送出筆數、排定的開始時間與倒數），以及最近 20 s／60 s 內依實驗 handle 統計的
/// `RX` 筆數。數據全由原生計算，畫面掛著時約每秒以 `experiment_getStatus` 讀一次；發送器跑在原生的
/// mesh 前景服務裡，關掉這個畫面不會停止發送。
class ExperimentScreen extends StatefulWidget {
  const ExperimentScreen({super.key, this.pollInterval = const Duration(seconds: 1), this.clock = DateTime.now});

  /// 多久向原生讀一次狀態。
  final Duration pollInterval;

  /// 本機牆鐘，用來顯示開始時間是今天還是明天、以及倒數。測試用。
  final DateTime Function() clock;

  @override
  State<ExperimentScreen> createState() => _ExperimentScreenState();
}

class _ExperimentScreenState extends State<ExperimentScreen> {
  static const _statusLabels = ['安全', '輕傷', '重傷'];
  static const _monospace = TextStyle(fontFamily: 'monospace');

  final _formKey = GlobalKey<FormState>();
  final _count = TextEditingController(text: '50');
  final _interval = TextEditingController(text: '1000');
  final _startAt = TextEditingController();

  /// 沒有預設：多支手機同時實驗時，忘了改裝置編號會讓接收端把兩支算成同一個來源。
  int? _device;
  int _ttl = ExperimentTtl.initial;

  /// run 期間持有 wake lock；E4 要關掉，否則手機無法休眠。
  bool _keepAwake = true;
  String _status = _statusLabels.first;

  Timer? _poller;

  /// 有一次 `experiment_getStatus` 還沒回來；期間的計時不再多送一次。
  bool _polling = false;

  /// 最近一次讀到的狀態；還沒讀到時是 null。讀取失敗時保留上一次的數字。
  ExperimentStatus? _live;

  /// 發送器狀態：來自最近一次讀取，或開始／停止的回傳值（哪個較新用哪個）。
  ExperimentSenderStatus _sender = ExperimentSenderStatus.idle;

  /// 最近一次讀取失敗的原因；成功後清掉。
  String? _pollError;

  /// 開始或停止正在等原生回覆。
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _poll();
    _poller = Timer.periodic(widget.pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _poller?.cancel();
    _count.dispose();
    _interval.dispose();
    _startAt.dispose();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final status = ExperimentStatus.fromMap(await BitchatBridge.getExperimentStatus());
      if (!mounted) return;
      setState(() {
        if (status == null) {
          _pollError = '讀取狀態失敗：原生沒有回傳狀態';
        } else {
          _live = status;
          _sender = status.sender;
          _pollError = null;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _pollError = '讀取狀態失敗：${experimentErrorReason(e)}');
    } finally {
      _polling = false;
    }
  }

  Future<void> _start() async {
    // 驗證不過時欄位下方會顯示原因，不呼叫原生。
    if (!_formKey.currentState!.validate()) return;
    final device = _device!;
    final count = ExperimentSenderInput.parseCount(_count.text)!;
    final intervalMs = ExperimentSenderInput.parseIntervalMs(_interval.text)!;
    final startAt = ExperimentSenderInput.parseStartAt(_startAt.text).startAt;
    await _callSender(
      '無法開始',
      () => BitchatBridge.startExperimentSender(
        device: device,
        count: count,
        intervalMs: intervalMs,
        ttl: _ttl,
        startAt: startAt,
        status: _status,
        keepAwake: _keepAwake,
      ),
    );
  }

  Future<void> _stop() => _callSender('無法停止', BitchatBridge.stopExperimentSender);

  /// 呼叫開始或停止，成功時立即顯示原生回傳的發送器狀態，失敗時以 [failure] 開頭說明原因。
  Future<void> _callSender(String failure, Future<Map<dynamic, dynamic>?> Function() call) async {
    setState(() => _busy = true);
    try {
      final sender = ExperimentSenderStatus.fromMap(await call());
      if (mounted && sender != null) setState(() => _sender = sender);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$failure：${experimentErrorReason(e)}')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('實驗工具（debug）')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_pollError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _pollError!,
                    key: const ValueKey('experiment-poll-error'),
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                ),
              _Section(title: '本機', children: _buildLocal()),
              _Section(title: '發送器', children: [..._buildSenderStatus(), const Divider(), _buildForm()]),
              _Section(title: '接收計數（RX）', children: [_buildRxTable()]),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildLocal() {
    final live = _live;
    final powerMode = live?.powerMode;
    final label = powerMode == null ? null : powerModeLabel(powerMode);
    return [
      _Field('目前直連數', live?.links?.toString() ?? '—', valueKey: 'experiment-links'),
      _Field('電源模式', powerMode == null ? '—' : (label == null ? powerMode : '$powerMode（$label）'),
          valueKey: 'experiment-power-mode'),
      // app 的電源模式不看系統省電模式，所以另外列出；開著時標出來，它會影響實驗結果。
      _Field(
        '系統省電',
        switch (live?.systemPowerSave) { true => '開（會影響實驗）', false => '關', null => '—' },
        valueKey: 'experiment-system-power-save',
        style: live?.systemPowerSave == true ? TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.bold) : null,
      ),
      _Field('本機 peerId', live == null ? '—' : (live.peerId ?? 'mesh 未啟動'),
          valueKey: 'experiment-peer-id', style: _monospace),
    ];
  }

  List<Widget> _buildSenderStatus() {
    final sender = _sender;
    final startsAt = sender.startsAt;
    final now = widget.clock();
    final countdown = startsAt != null && sender.state == ExperimentSenderState.waiting
        ? formatExperimentCountdown(startsAt, now)
        : null;
    return [
      _Field('狀態', sender.state.label, valueKey: 'experiment-sender-state'),
      if (sender.state != ExperimentSenderState.idle) ...[
        _Field('已送出', '${sender.sent} / ${sender.total}', valueKey: 'experiment-sender-progress'),
        // 廣播沒有回條；寫出時有沒有鏈路是送出端唯一看得到的結果。無鏈路或未收下都代表沒人收得到。
        _Field(
          '寫出結果',
          '有鏈路 ${sender.written}・無鏈路 ${sender.noLink}・mesh 未收下 ${sender.failed}',
          valueKey: 'experiment-sender-outcome',
          style: sender.noLink > 0 || sender.failed > 0
              ? TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.bold)
              : null,
        ),
        _Field(
          '本次',
          [
            sender.handle ?? '—',
            'TTL ${sender.ttl ?? '—'}',
            '間隔 ${sender.intervalMs ?? '—'} ms',
            if (sender.keepAwake != null) sender.keepAwake! ? '保持喚醒' : '不保持喚醒',
          ].join('・'),
          valueKey: 'experiment-sender-job',
          style: _monospace,
        ),
      ],
      if (startsAt != null)
        _LabeledRow(
          label: '開始時間',
          child: Wrap(
            spacing: 12,
            children: [
              Text(
                formatExperimentStart(startsAt, now),
                key: const ValueKey('experiment-sender-start'),
                // 不是今天就標出來：多半是開始時間打成已經過去的時刻，被排到明天了。
                style: experimentStartsToday(startsAt, now)
                    ? null
                    : TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.bold),
              ),
              if (countdown != null) Text('倒數 $countdown', key: const ValueKey('experiment-sender-countdown')),
            ],
          ),
        ),
    ];
  }

  Widget _buildForm() {
    final device = _device;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<int>(
            key: const ValueKey('experiment-device'),
            decoration: const InputDecoration(labelText: '裝置編號'),
            hint: Text('選擇 1–${ExperimentHandles.devices.last}'),
            items: [
              for (final d in ExperimentHandles.devices)
                DropdownMenuItem(value: d, child: Text('$d（${ExperimentHandles.forDevice(d)}）')),
            ],
            onChanged: (d) => setState(() => _device = d),
            validator: (d) => d == null ? '請選擇裝置編號' : null,
          ),
          if (device != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'handle：${ExperimentHandles.forDevice(device)}',
                key: const ValueKey('experiment-device-handle'),
                style: _monospace,
              ),
            ),
          TextFormField(
            key: const ValueKey('experiment-count'),
            controller: _count,
            decoration: const InputDecoration(labelText: '筆數 N'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: (text) => ExperimentSenderInput.parseCount(text ?? '') == null ? '筆數要是 1 以上的整數' : null,
          ),
          TextFormField(
            key: const ValueKey('experiment-interval'),
            controller: _interval,
            decoration: const InputDecoration(labelText: '間隔（ms）', helperText: '0 為突發測試'),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            validator: (text) =>
                ExperimentSenderInput.parseIntervalMs(text ?? '') == null ? '間隔要是 0 以上的整數（ms）' : null,
          ),
          const SizedBox(height: 12),
          _LabeledRow(
            label: 'TTL',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Slider(
                  key: const ValueKey('experiment-ttl'),
                  min: ExperimentTtl.min.toDouble(),
                  max: ExperimentTtl.max.toDouble(),
                  divisions: ExperimentTtl.max - ExperimentTtl.min,
                  label: '$_ttl',
                  value: _ttl.toDouble(),
                  onChanged: (value) => setState(() => _ttl = value.round()),
                ),
                Text(ExperimentTtl.reach(_ttl), key: const ValueKey('experiment-ttl-reach')),
              ],
            ),
          ),
          TextFormField(
            key: const ValueKey('experiment-start-at'),
            controller: _startAt,
            decoration: const InputDecoration(
              labelText: '開始時間',
              hintText: 'HH:mm:ss',
              helperText: '本機時間；留空立即開始，已過的時刻排到明天',
            ),
            keyboardType: TextInputType.datetime,
            validator: (text) => ExperimentSenderInput.parseStartAt(text ?? '').valid
                ? null
                : '請輸入 HH:mm:ss（24 小時制），或留空立即開始',
          ),
          const SizedBox(height: 12),
          _LabeledRow(
            label: 'Status',
            child: SegmentedButton<String>(
              key: const ValueKey('experiment-status'),
              segments: [for (final s in _statusLabels) ButtonSegment(value: s, label: Text(s))],
              selected: {_status},
              onSelectionChanged: (selected) => setState(() => _status = selected.single),
            ),
          ),
          SwitchListTile(
            key: const ValueKey('experiment-keep-awake'),
            contentPadding: EdgeInsets.zero,
            title: const Text('保持喚醒'),
            subtitle: const Text('螢幕關閉也照排程送。E4 要關掉，否則手機無法休眠'),
            value: _keepAwake,
            onChanged: (value) => setState(() => _keepAwake = value),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  key: const ValueKey('experiment-start'),
                  onPressed: _busy || _sender.state.isRunning ? null : _start,
                  child: const Text('開始'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('experiment-stop'),
                  onPressed: _busy ? null : _stop,
                  child: const Text('停止'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRxTable() {
    final live = _live;
    String count(Map<String, int>? counts, String handle) => counts == null ? '—' : '${counts[handle] ?? 0}';
    const header = TextStyle(fontWeight: FontWeight.bold);
    return Table(
      columnWidths: const {0: FlexColumnWidth(2), 1: FlexColumnWidth(), 2: FlexColumnWidth()},
      children: [
        const TableRow(children: [
          Text('來源 handle', style: header),
          Text('20 s', style: header, textAlign: TextAlign.end),
          Text('60 s', style: header, textAlign: TextAlign.end),
        ]),
        for (final handle in (live ?? const ExperimentStatus()).rxHandles)
          TableRow(children: [
            Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(handle, style: _monospace)),
            Text(count(live?.rx20s, handle), key: ValueKey('experiment-rx20-$handle'), textAlign: TextAlign.end),
            Text(count(live?.rx60s, handle), key: ValueKey('experiment-rx60-$handle'), textAlign: TextAlign.end),
          ]),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// 一列「標籤：內容」。
class _LabeledRow extends StatelessWidget {
  const _LabeledRow({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(width: 96, child: Text(label, style: TextStyle(color: Theme.of(context).hintColor))),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: child)),
        ],
      ),
    );
  }
}

/// 一列「標籤：文字」；文字帶 [valueKey]，方便測試找到它。
class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {required this.valueKey, this.style});

  final String label;
  final String value;
  final String valueKey;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) =>
      _LabeledRow(label: label, child: Text(value, key: ValueKey(valueKey), style: style));
}
