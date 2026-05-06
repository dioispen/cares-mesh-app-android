import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

const _kShelterUrl = 'https://kiang.github.io/air_raid_shelter/';

class ShelterScreen extends StatefulWidget {
  const ShelterScreen({super.key});

  @override
  State<ShelterScreen> createState() => _ShelterScreenState();
}

class _ShelterScreenState extends State<ShelterScreen> {
  static const _bg         = Color(0xFFF7F3EC);
  static const _textPrimary= Color(0xFF3D2C1E);
  static const _brown      = Color(0xFF5C3D2E);

  InAppWebViewController? _webController;
  bool _isLoading = true;
  double _loadProgress = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: const Text(
          '防空洞地圖',
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
            onPressed: () => launchUrl(
              Uri.parse(_kShelterUrl),
              mode: LaunchMode.externalApplication,
            ),
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
          Container(
            width: double.infinity,
            color: _brown.withValues(alpha: 0.06),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.info_outline_rounded,
                    size: 12, color: Color(0xFF8C7B6E)),
                const SizedBox(width: 4),
                const Text('資料來源：',
                    style:
                        TextStyle(fontSize: 10, color: Color(0xFF8C7B6E))),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse(_kShelterUrl),
                      mode: LaunchMode.externalApplication),
                  child: const Text(
                    'kiang.github.io/air_raid_shelter',
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.blue,
                        decoration: TextDecoration.underline),
                  ),
                ),
                const Text('  ／  ',
                    style:
                        TextStyle(fontSize: 10, color: Color(0xFF8C7B6E))),
                GestureDetector(
                  onTap: () => launchUrl(Uri.parse('https://adr.npa.gov.tw/'),
                      mode: LaunchMode.externalApplication),
                  child: const Text(
                    '內政部警政署（NPA）',
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.blue,
                        decoration: TextDecoration.underline),
                  ),
                ),
              ],
            ),
          ),
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
