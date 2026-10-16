import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/mascot_service.dart';

const _kShelterUrl = 'https://kiang.github.io/air_raid_shelter/';
const _kNpaUrl = 'https://adr.npa.gov.tw/';

class ShelterScreen extends StatefulWidget {
  const ShelterScreen({super.key});

  @override
  State<ShelterScreen> createState() => _ShelterScreenState();
}

class _ShelterScreenState extends State<ShelterScreen> with RouteAware {
  static const _bg         = Color(0xFFF7F3EC);
  static const _textPrimary= Color(0xFF3D2C1E);
  static const _brown      = Color(0xFF5C3D2E);

  InAppWebViewController? _webController;
  bool _isLoading = true;
  double _loadProgress = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    mascotRouteObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    mascotRouteObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPush() => mascotOptionsNotifier.value = shelterOptions;

  @override
  void didPopNext() => mascotOptionsNotifier.value = shelterOptions;

  static void _openExternal(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text(
          '防災避難所',
          style: TextStyle(
              fontSize: 20, fontWeight: FontWeight.w800, color: _textPrimary),
        ),
        iconTheme: const IconThemeData(color: _textPrimary),
        actions: [
          // 重新整理
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: _textPrimary),
            tooltip: '重新整理',
            onPressed: () => _webController?.reload(),
          ),
          // 在瀏覽器中開啟
          IconButton(
            icon: const Icon(Icons.open_in_browser_rounded, color: _textPrimary),
            tooltip: '在瀏覽器中開啟',
            onPressed: () => _openExternal(_kShelterUrl),
          ),
        ],
      ),
      body: Column(
        children: [
          // 進度條
          if (_isLoading)
            LinearProgressIndicator(
              value: _loadProgress > 0 ? _loadProgress / 100 : null,
              backgroundColor: _brown.withValues(alpha: 0.1),
              valueColor: AlwaysStoppedAnimation<Color>(_brown),
              minHeight: 3,
            ),

          // WebView
          Expanded(
            child: kIsWeb ? _buildWebIframe() : _buildNativeWebView(),
          ),

          // 來源標示
          ShelterSourceFooter(onOpen: _openExternal),
        ],
      ),
    );
  }

  // ── Flutter Web：使用 InAppWebView（iframe 模式）────────────
  Widget _buildWebIframe() {
    return InAppWebView(
      initialUrlRequest:
          URLRequest(url: WebUri(_kShelterUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        transparentBackground: true,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
      ),
      onWebViewCreated: (controller) => _webController = controller,
      onLoadStart: (controller, url) {
        setState(() {
          _isLoading = true;
          _loadProgress = 0;
        });
      },
      onProgressChanged: (controller, progress) {
        setState(() => _loadProgress = progress.toDouble());
      },
      onLoadStop: (controller, url) {
        setState(() => _isLoading = false);
      },
    );
  }

  // ── Android / iOS：原生 WebView ───────────────────────────
  Widget _buildNativeWebView() {
    return InAppWebView(
      initialUrlRequest:
          URLRequest(url: WebUri(_kShelterUrl)),
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        geolocationEnabled: true,
        useOnLoadResource: true,
        allowsInlineMediaPlayback: true,
        mediaPlaybackRequiresUserGesture: false,
        cacheEnabled: true,
      ),
      onWebViewCreated: (controller) => _webController = controller,
      onLoadStart: (controller, url) {
        setState(() {
          _isLoading = true;
          _loadProgress = 0;
        });
      },
      onProgressChanged: (controller, progress) {
        setState(() => _loadProgress = progress.toDouble());
      },
      onLoadStop: (controller, url) {
        setState(() => _isLoading = false);
      },
      onGeolocationPermissionsShowPrompt: (controller, origin) async {
        return GeolocationPermissionShowPromptResponse(
            origin: origin, allow: true, retain: true);
      },
    );
  }
}

/// 地圖下方的資料來源列：兩個來源都可以點開外部瀏覽器。
///
/// 整列是一段可換行的文字（#79）：360dp 寬的手機或放大字體時，第二個來源換到下一行，
/// 不會超出畫面右側。
class ShelterSourceFooter extends StatefulWidget {
  const ShelterSourceFooter({super.key, required this.onOpen});

  /// 點了來源連結，帶入它的網址。
  final ValueChanged<String> onOpen;

  @override
  State<ShelterSourceFooter> createState() => _ShelterSourceFooterState();
}

class _ShelterSourceFooterState extends State<ShelterSourceFooter> {
  static const _brown = Color(0xFF5C3D2E);
  static const _muted = TextStyle(fontSize: 10, color: Color(0xFF8C7B6E));
  static const _link = TextStyle(
      fontSize: 10, color: Colors.blue, decoration: TextDecoration.underline);

  late final TapGestureRecognizer _shelterTap = TapGestureRecognizer()
    ..onTap = () => widget.onOpen(_kShelterUrl);
  late final TapGestureRecognizer _npaTap = TapGestureRecognizer()
    ..onTap = () => widget.onOpen(_kNpaUrl);

  @override
  void dispose() {
    _shelterTap.dispose();
    _npaTap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: _brown.withValues(alpha: 0.06),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Text.rich(
        TextSpan(
          style: _muted,
          children: [
            const WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsets.only(right: 4),
                child: Icon(Icons.info_outline_rounded,
                    size: 12, color: Color(0xFF8C7B6E)),
              ),
            ),
            const TextSpan(text: '資料來源：'),
            TextSpan(
                text: 'kiang.github.io/air_raid_shelter',
                style: _link,
                recognizer: _shelterTap),
            const TextSpan(text: '  ／  '),
            TextSpan(
                text: '內政部警政署（NPA）', style: _link, recognizer: _npaTap),
          ],
        ),
      ),
    );
  }
}
