import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../auth/auth_controller.dart';

/// Loads the File Browser server's own `/login` page in a WebView so the user
/// can solve the captcha on the correct domain. Credentials are pre-filled from
/// secure storage; after a successful login the JWT is read out of
/// `localStorage["jwt"]` and handed back to the [AuthController].
class WebViewLoginScreen extends StatefulWidget {
  const WebViewLoginScreen({super.key, required this.target});

  final LoginTarget target;

  @override
  State<WebViewLoginScreen> createState() => _WebViewLoginScreenState();
}

class _WebViewLoginScreenState extends State<WebViewLoginScreen> {
  late final WebViewController _controller;
  Timer? _poller;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _prefillCredentials();
            _startHarvesting();
          },
        ),
      )
      ..loadRequest(Uri.parse('${widget.target.baseUrl}/login'));
  }

  @override
  void dispose() {
    _poller?.cancel();
    super.dispose();
  }

  /// Set the Vue-bound inputs and dispatch input events so the framework picks
  /// the values up (a plain value assignment is ignored by v-model).
  void _prefillCredentials() {
    final u = jsonEncode(widget.target.username);
    final p = jsonEncode(widget.target.password);
    _controller.runJavaScript('''
      (function () {
        function setVal(el, val) {
          var d = Object.getOwnPropertyDescriptor(
              window.HTMLInputElement.prototype, 'value');
          d.set.call(el, val);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
        }
        var tries = 0;
        var iv = setInterval(function () {
          tries++;
          var user = document.querySelector('#login input[type=text]');
          var pass = document.querySelector('#login input[type=password]');
          if (user && pass) {
            setVal(user, $u);
            setVal(pass, $p);
            clearInterval(iv);
          } else if (tries > 50) {
            clearInterval(iv);
          }
        }, 150);
      })();
    ''');
  }

  void _startHarvesting() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(milliseconds: 600), (_) async {
      if (_done) return;
      final raw =
          await _controller.runJavaScriptReturningResult('localStorage.getItem("jwt")');
      final token = _normalizeJwt(raw);
      if (token != null) {
        _done = true;
        _poller?.cancel();
        if (mounted) {
          await context.read<AuthController>().completeWebLogin(token);
        }
      }
    });
  }

  /// runJavaScriptReturningResult may return the value quoted/escaped or the
  /// literal `null`; normalize to a bare JWT or null.
  String? _normalizeJwt(Object raw) {
    var s = raw.toString().trim();
    if (s.isEmpty || s == 'null') return null;
    if (s.startsWith('"') && s.endsWith('"') && s.length >= 2) {
      try {
        s = jsonDecode(s) as String;
      } catch (_) {
        s = s.substring(1, s.length - 1);
      }
    }
    s = s.replaceAll(r'\/', '/');
    return s.split('.').length == 3 ? s : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sign in'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => context.read<AuthController>().cancelWebLogin(),
        ),
      ),
      body: Column(
        children: [
          const Material(
            color: Color(0xFFE8EAF6),
            child: Padding(
              padding: EdgeInsets.all(10),
              child: Text(
                'Credentials are filled in. Solve the captcha and tap the '
                "page's sign-in button.",
                style: TextStyle(fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
