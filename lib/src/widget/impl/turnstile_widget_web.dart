// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui;

import 'package:cloudflare_turnstile/src/controller/impl/turnstile_controller_web.dart';
import 'package:cloudflare_turnstile/src/turnstile_exception.dart';
import 'package:cloudflare_turnstile/src/widget/interface.dart' as i;
import 'package:cloudflare_turnstile/src/widget/turnstile_options.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Source of Cloudflare's Turnstile script. Loaded with `render=explicit`
/// and WITHOUT an `onload=` callback: rendering is driven per widget
/// instance, so no one-shot global ready callback is needed (or can be
/// overwritten by another instance).
const String _turnstileScriptSrc =
    'https://challenges.cloudflare.com/turnstile/v0/api.js';

/// Cached script load shared by every widget instance, so the script is
/// injected at most once per page. Reset to `null` on failure so a later
/// widget can retry the load instead of failing forever.
Completer<void>? _scriptLoaderCompleter;

/// Whether Cloudflare's `window.turnstile` runtime is available.
bool _isTurnstileRuntimeReady() =>
    web.window.hasProperty('turnstile'.toJS).toDart;

/// Ensures Cloudflare's `api.js` is loaded and `window.turnstile` is
/// defined before completing.
///
/// Idempotent: concurrent and repeated callers share a single in-flight
/// load, and the script tag is injected at most once - even when a tag
/// already exists from a previous page state (e.g. a hot restart). This
/// prevents the "Turnstile already has been loaded" double-injection.
Future<void> _ensureTurnstileScriptLoaded() {
  final existing = _scriptLoaderCompleter;
  if (existing != null) return existing.future;

  final completer = Completer<void>();
  _scriptLoaderCompleter = completer;

  if (_isTurnstileRuntimeReady()) {
    completer.complete();
    return completer.future;
  }

  // Reuse a script tag injected earlier (by a previous instance or before
  // a hot restart); only inject when none exists.
  const selector = 'script[src^="$_turnstileScriptSrc"]';
  if (web.document.querySelector(selector) == null) {
    final script = web.HTMLScriptElement()
      ..id = 'turnstile-script'
      ..async = true
      ..defer = true
      ..src = '$_turnstileScriptSrc?render=explicit';
    // Fail fast when the script is blocked (offline, ad-blocker) instead
    // of waiting out the poll timeout. The dead tag is removed so a later
    // attempt injects a fresh one rather than polling a corpse.
    script.addEventListener(
      'error',
      ((web.Event _) {
        if (!completer.isCompleted) {
          script.remove();
          _scriptLoaderCompleter = null;
          completer.completeError(
            TimeoutException('Turnstile api.js failed to load.'),
          );
        }
      }).toJS,
    );
    web.document.head?.append(script);
  }

  // The script's `load` event can fire just before `window.turnstile` is
  // defined, and a reused tag may have fired it already - so poll for the
  // runtime instead of trusting load events.
  var waited = Duration.zero;
  const pollInterval = Duration(milliseconds: 50);
  const loadTimeout = Duration(milliseconds: 8000);
  Timer.periodic(pollInterval, (timer) {
    if (completer.isCompleted) {
      timer.cancel();
      return;
    }
    if (_isTurnstileRuntimeReady()) {
      timer.cancel();
      completer.complete();
      return;
    }
    waited += pollInterval;
    if (waited >= loadTimeout) {
      timer.cancel();
      _scriptLoaderCompleter = null;
      completer.completeError(
        TimeoutException('Turnstile api.js failed to load.', loadTimeout),
      );
    }
  });

  return completer.future;
}

@JS('turnstile.render')
external JSString? _renderTurnstile(web.Element element, JSObject params);

@JS('turnstile.remove')
external void _removeTurnstile(JSString widgetId);

/// Deregisters a rendered widget from Cloudflare's runtime before its DOM
/// node is removed. Without this, the runtime keeps polling a dead widget
/// and logs "Cannot find Widget cf-chl-widget-..." / "seem to have hung".
/// Safe for ids the runtime no longer tracks (Cloudflare throws for those).
void _safeRemoveTurnstileWidget(String? widgetId) {
  if (widgetId == null || widgetId.isEmpty) return;
  try {
    _removeTurnstile(widgetId.toJS);
  } on Object catch (_) {
    // Already removed or never tracked - nothing to clean up.
  }
}

/// Creates the bare container element a Turnstile widget renders into.
/// All widget configuration travels through the `turnstile.render` params
/// object, so no `data-*` attributes are needed here.
web.HTMLDivElement _buildContainer(String className) => web.HTMLDivElement()
  ..style.width = '100%'
  ..style.height = '100%'
  ..className = className;

/// Builds the options object passed to `turnstile.render`.
///
/// Callbacks are real per-instance JS functions instead of names of
/// globals, so concurrently existing (or orphaned) widgets can never
/// receive each other's events - the cause of cross-instance state
/// corruption and spurious 300xxx errors in earlier versions.
JSObject _buildRenderParams({
  required String siteKey,
  required TurnstileOptions options,
  required JSFunction onToken,
  required JSFunction onError,
  String? action,
  String? cData,
  String? appearance,
  JSFunction? onTokenExpired,
  JSFunction? onTimeout,
  JSFunction? onBeforeInteractive,
}) {
  final retry = options.retryAutomatically ? 'auto' : 'never';
  final params = JSObject()
    ..setProperty('sitekey'.toJS, siteKey.toJS)
    ..setProperty('theme'.toJS, options.theme.name.toJS)
    ..setProperty('size'.toJS, options.size.name.toJS)
    ..setProperty('language'.toJS, options.language.toJS)
    ..setProperty('retry'.toJS, retry.toJS)
    ..setProperty(
      'retry-interval'.toJS,
      options.retryInterval.inMilliseconds.toJS,
    )
    ..setProperty('refresh-expired'.toJS, options.refreshExpired.name.toJS)
    ..setProperty('refresh-timeout'.toJS, options.refreshTimeout.name.toJS)
    ..setProperty('feedback-enabled'.toJS, false.toJS)
    ..setProperty('callback'.toJS, onToken)
    ..setProperty('error-callback'.toJS, onError);
  if (action != null && action.isNotEmpty) {
    params.setProperty('action'.toJS, action.toJS);
  }
  if (cData != null && cData.isNotEmpty) {
    params.setProperty('cData'.toJS, cData.toJS);
  }
  if (appearance != null) {
    params.setProperty('appearance'.toJS, appearance.toJS);
  }
  if (onTokenExpired != null) {
    params.setProperty('expired-callback'.toJS, onTokenExpired);
  }
  if (onTimeout != null) {
    params.setProperty('timeout-callback'.toJS, onTimeout);
  }
  if (onBeforeInteractive != null) {
    params.setProperty(
      'before-interactive-callback'.toJS,
      onBeforeInteractive,
    );
  }
  return params;
}

String _createViewType() {
  final widgetId = '_${DateTime.now().microsecondsSinceEpoch}';
  return '_turnstile_$widgetId';
}

/// Cloudflare Turnstile web implementation
class CloudflareTurnstile extends StatefulWidget
    implements i.CloudflareTurnstile {
  /// Create a Cloudflare Turnstile Widget
  CloudflareTurnstile({
    required this.siteKey,
    super.key,
    this.action,
    this.cData,
    this.baseUrl = 'http://localhost/',
    TurnstileOptions? options,
    this.controller,
    this.onTokenReceived,
    this.onTokenExpired,
    this.onError,
    this.onTimeout,
  }) : options = options ?? TurnstileOptions() {
    if (action != null) {
      assert(
        action!.length <= 32 && RegExp(r'^[a-zA-Z0-9_-]*$').hasMatch(action!),
        'action must be contain up to 32 characters including _ and -.',
      );
    }

    if (cData != null) {
      assert(
        cData!.length <= 32 && RegExp(r'^[a-zA-Z0-9_-]*$').hasMatch(cData!),
        'action must be contain up to 32 characters including _ and -.',
      );
    }

    assert(
      this.options.retryInterval.inMilliseconds > 0 &&
          this.options.retryInterval.inMilliseconds <= 900000,
      'Duration must be greater than 0 and less than or equal to 900000 milliseconds.',
    );
  }

  /// Create a Cloudflare Turnstile invisible widget.
  ///
  /// [siteKey] - A Cloudflare Turnstile sitekey.
  /// It`s likely generated or obtained from the Cloudflare dashboard.
  ///
  /// [action] - A customer value that can be used to differentiate widgets under
  /// the some sitekey in analytics and witch is returned upon validation.
  ///
  /// [cData] - A customer payload that can be used to attach customer data to the
  /// challenge throughout its issuance and which is returned upon validation.
  ///
  /// [baseUrl] - A website url corresponding current turnstile widget.
  ///
  /// [options] - Configuration options for the Turnstile widget.
  ///
  /// [onTokenReceived] - A Callback invoked upon success of the challange.
  /// The callback is passed a `token` that can be validated.
  ///
  /// [onTokenExpired] - A Callback invoke when the token expires and does not
  /// reset the widget.
  factory CloudflareTurnstile.invisible({
    required String siteKey,
    String? action,
    String? cData,
    String baseUrl = 'http://localhost',
    i.OnTokenReceived? onTokenReceived,
    i.OnTokenExpired? onTokenExpired,
    i.OnTimeout? onTimeout,
    TurnstileOptions? options,
  }) {
    return _TurnstileInvisible.init(
      siteKey: siteKey,
      action: action,
      cData: cData,
      baseUrl: baseUrl,
      onTokenReceived: onTokenReceived,
      onTokenExpired: onTokenExpired,
      onTimeout: onTimeout,
      options: options ?? TurnstileOptions(),
    );
  }

  /// This [siteKey] is associated with the corresponding widget configuration
  /// and is created upon the widget creation.
  ///
  /// It`s likely generated or obtained from the CloudFlare dashboard.
  @override
  final String siteKey;

  /// A customer value that can be used to differentiate widgets under the
  /// same sitekey in analytics and which is returned upon validation.
  ///
  /// This can only contain up to 32 alphanumeric characters including _ and -.
  @override
  final String? action;

  /// A customer payload that can be used to attach customer data to the
  /// challenge throughout its issuance and which is returned upon validation.
  ///
  /// This can only contain up to 255 alphanumeric characters including _ and -.
  @override
  final String? cData;

  /// The base URL of the Turnstile site.
  ///
  /// Defaults to 'http://localhost/'.
  @override
  final String baseUrl;

  /// Configuration options for the Turnstile widget.
  ///
  /// If no options are provided, the default [TurnstileOptions] are used.
  @override
  final TurnstileOptions options;

  /// A controller for managing interactions with the Turnstile widget.
  @override
  final TurnstileController? controller;

  /// A Callback invoked upon success of the challange.
  /// The callback is passed a `token` that can be validated.
  ///
  /// example:
  /// ```dart
  /// CloudflareTurnstile(
  ///   siteKey: '3x00000000000000000000FF',
  ///   onTokenReceived: (String token) {
  ///     print('Token: $token');
  ///   },
  /// ),
  /// ```
  @override
  final i.OnTokenReceived? onTokenReceived;

  /// A Callback invoke when the token expires and does not
  /// reset the widget.
  ///
  /// example:
  /// ```dart
  /// CloudflareTurnstile(
  ///   siteKey: '3x00000000000000000000FF',
  ///   onTokenExpired: () {
  ///     print('Token Expired');
  ///   },
  /// ),
  /// ```
  @override
  final i.OnTokenExpired? onTokenExpired;

  /// A Callback invoke when there is an error
  /// (e.g network error or challange failed).
  ///
  /// This widget will only be displayed if the TurnstileException's `retryable`
  /// property is set to `true`. For non-retriable errors, this callback may still
  /// be invoked, but the display or handling of these errors might be managed
  /// internally by the Turnstile widget or handled differently.
  ///
  /// example:
  /// ```dart
  /// CloudflareTurnstile(
  ///   siteKey: '3x00000000000000000000FF',
  ///   errorBuilder: (error) {
  ///     print(error.message);
  ///   },
  /// ),
  /// ```
  ///
  /// Refer to [Client-side errors](https://developers.cloudflare.com/turnstile/troubleshooting/client-side-errors/).
  @override
  final i.OnError? onError;

  /// Called when the Turnstile script/widget fails to load within a timeout.
  @override
  final i.OnTimeout? onTimeout;

  @override
  State<CloudflareTurnstile> createState() => _CloudflareTurnstileState();

  /// Retrives the current token from the widget.
  ///
  /// Returns `null` if no token is available.
  @override
  String? get token => throw UnimplementedError(
        'This function cannot be called in interactive widget mode.',
      );

  /// Retrives the current widget id.
  ///
  /// This `id` is used to uniquely identify the Turnstile widget instance.
  @override
  String? get id => throw UnimplementedError(
        'This function cannot be called in interactive widget mode.',
      );

  /// The function can be called when widget mey become expired and
  /// needs to be refreshed otherwise, it will start a new challenge.
  ///
  /// This method can only be called when [id] is not null.
  ///
  ///
  /// example:
  /// ```dart
  /// // Initialize turnstile instance
  /// final turnstile = CloudflareTurnstile.invisible(
  ///   siteKey: '1x00000000000000000000BB', // Replace with your actual site key
  /// );
  ///
  /// await turnstile.isExpired();
  ///
  /// // finally clean up widget.
  /// await turnstile.dispose();
  /// ```
  @override
  Future<void> refresh({bool forceRefresh = true}) {
    throw UnimplementedError(
      'This function cannot be called in interactive widget mode.',
    );
  }

  /// This function starts a Cloudflare Turnstile challenge and returns token
  /// or `null` if challenge failed or error occured.
  ///
  /// example:
  /// ```dart
  /// // Initialize turnstile instance
  /// final turnstile = CloudflareTurnstile.invisible(
  ///   siteKey: '1x00000000000000000000BB', // Replace with your actual site key
  /// );
  ///
  /// final token = await turnstile.getToken();
  ///
  /// print(token);
  ///
  /// // finally clean up widget.
  /// await turnstile.dispose();
  /// ```
  @override
  Future<String?> getToken() {
    throw UnimplementedError(
      'This function cannot be called in interactive widget mode.',
    );
  }

  /// The function that check if a widget has expired.
  ///
  /// This method can only be called when [id] is not null.
  ///
  ///
  /// example:
  /// ```dart
  /// // Initialize turnstile instance
  /// final turnstile = CloudflareTurnstile.invisible(
  ///   siteKey: '1x00000000000000000000BB', // Replace with your actual site key
  /// );
  ///
  /// // ...
  ///
  /// bool isTokenExpired = await turnstile.isExpired();
  /// print(isTokenExpired);
  ///
  /// // finally clean up widget.
  /// await turnstile.dispose();
  /// ```
  @override
  Future<bool> isExpired() {
    throw UnimplementedError(
      'This function cannot be called in interactive widget mode.',
    );
  }

  /// Dispose invisible Turnstile widget.
  ///
  ///
  /// This should be called when the widget is no longer needed to free
  /// up resources and clean up.
  @override
  Future<void> dispose() {
    throw UnimplementedError(
      'This function cannot be called in interactive widget mode.',
    );
  }
}

class _CloudflareTurnstileState extends State<CloudflareTurnstile> {
  late web.HTMLDivElement _widget;
  late String _widgetViewId;

  String? widgetId;

  bool _isWidgetReady = false;
  TurnstileException? _hasError;
  Timer? _scriptLoadTimer;
  Timer? _domAttachTimer;
  bool _isDisposed = false;
  bool _viewCreated = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _setTurnstileTheme();
      }
    });

    _widgetViewId = _createViewType();
    _widget = _buildContainer('cf-turnstile_$_widgetViewId');
    _registerView(_widgetViewId);
  }

  /// Awaits the shared script load, then renders once the container is
  /// actually attached to the document. Rendering into a detached node
  /// leaves an iframe that never paints (a blank widget), so attachment
  /// is verified before calling `turnstile.render`.
  Future<void> _loadAndRender() async {
    try {
      await _ensureTurnstileScriptLoaded();
    } on Object catch (_) {
      if (_isDisposed || !mounted) return;
      _addError(
        const TurnstileException('Failed to load the Turnstile script.'),
      );
      return;
    }
    if (_isDisposed || !mounted || !_viewCreated) return;

    if (_widget.isConnected) {
      _renderTurnstileWidget();
      return;
    }

    var waited = Duration.zero;
    const pollInterval = Duration(milliseconds: 50);
    const attachTimeout = Duration(milliseconds: 1500);
    _domAttachTimer?.cancel();
    _domAttachTimer = Timer.periodic(pollInterval, (timer) {
      if (_isDisposed || !mounted) {
        timer.cancel();
        return;
      }
      if (_widget.isConnected) {
        timer.cancel();
        _renderTurnstileWidget();
        return;
      }
      waited += pollInterval;
      if (waited >= attachTimeout) {
        timer.cancel();
        _addError(
          const TurnstileException('Failed to render the Turnstile widget.'),
        );
      }
    });
  }

  void _renderTurnstileWidget() {
    if (_isDisposed || !mounted) return;
    if (widgetId != null) return; // Already rendered

    final params = _buildRenderParams(
      siteKey: widget.siteKey,
      options: widget.options,
      action: widget.action,
      cData: widget.cData,
      onToken: ((JSString token) {
        if (_isDisposed) return;
        widget.onTokenReceived?.call(token.toDart);
        widget.controller?.token = token.toDart;
      }).toJS,
      // Deliberately returns nothing: Cloudflare then still logs the error
      // code to the browser console (where console-capture tooling like
      // PostHog picks it up) in addition to the [_addError] path here.
      onError: ((JSString code) {
        if (!_isDisposed && mounted) {
          final errorCode = int.tryParse(code.toDart) ?? -1;
          _addError(TurnstileException.fromCode(errorCode));
        }
      }).toJS,
      onTokenExpired: (() {
        if (_isDisposed) return;
        widget.onTokenExpired?.call();
      }).toJS,
      onTimeout: (() {
        if (_isDisposed) return;
        widget.onTimeout?.call();
      }).toJS,
    );

    JSString? renderedId;
    try {
      renderedId = _renderTurnstile(_widget, params);
    } on Object catch (_) {
      renderedId = null;
    }

    // A failed render previously still marked the widget ready, leaving
    // an opaque empty box. Surface it as a (non-retryable) error instead.
    if (renderedId == null || renderedId.toDart.isEmpty) {
      _addError(
        const TurnstileException('Failed to render the Turnstile widget.'),
      );
      return;
    }

    widgetId = renderedId.toDart;
    widget.controller?.widgetId = widgetId;
    if (mounted) {
      setState(() => _isWidgetReady = true);
    }
    widget.controller?.isWidgetReady = _isWidgetReady;
    _scriptLoadTimer?.cancel();
  }

  void _setTurnstileTheme() {
    if (widget.options.theme == TurnstileTheme.auto) {
      final brightness = MediaQuery.of(context).platformBrightness;
      final isDark = brightness == Brightness.dark;
      widget.options.theme =
          isDark ? TurnstileTheme.dark : TurnstileTheme.light;
    }
  }

  void _registerView(String viewType) {
    ui.platformViewRegistry.registerViewFactory(
      viewType,
      (int viewId, {Object? params}) {
        return _widget;
      },
    );
  }

  void _addError(TurnstileException error) {
    if (_isDisposed || !mounted) return;
    setState(() {
      _hasError = error;
      _isWidgetReady = error.retryable;
      widget.controller?.error = error;
      widget.controller?.isWidgetReady = error.retryable;
      widget.onError?.call(error);
    });
  }

  late final Widget _view = HtmlElementView(
    key: widget.key,
    viewType: _widgetViewId,
    onPlatformViewCreated: (id) {
      _viewCreated = true;
      _scriptLoadTimer?.cancel();
      _scriptLoadTimer = Timer(const Duration(milliseconds: 8000), () {
        if (_isDisposed || !mounted) return;
        if (!_isWidgetReady) {
          widget.onTimeout?.call();
        }
      });

      unawaited(_loadAndRender());
    },
  );

  @override
  void dispose() {
    _isDisposed = true;
    _scriptLoadTimer?.cancel();
    _scriptLoadTimer = null;
    _domAttachTimer?.cancel();
    _domAttachTimer = null;
    // Deregister from Cloudflare's runtime BEFORE removing the DOM node,
    // otherwise the runtime keeps tracking an orphaned widget.
    _safeRemoveTurnstileWidget(widgetId);
    widgetId = null;
    _widget.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _setTurnstileTheme();

    final primaryColor = widget.options.theme == TurnstileTheme.light
        ? const Color(0xFFFAFAFA)
        : const Color(0xFF232323);
    final secondaryColor = widget.options.theme == TurnstileTheme.light
        ? const Color(0xFFDEDEDE)
        : const Color(0xFF9A9A9A);
    final adaptiveBorderColor =
        _isWidgetReady ? secondaryColor : Colors.transparent;

    final isErrorResolvable = _hasError != null && _hasError!.retryable == true;

    final turnstileWidget = Visibility(
      visible: _hasError == null || isErrorResolvable,
      child: AnimatedContainer(
        duration: widget.options.animationDuration!,
        width: _isWidgetReady ? widget.options.size.width : 0.1,
        height: _isWidgetReady ? widget.options.size.height : 0.1,
        curve: widget.options.curves!,
        foregroundDecoration: BoxDecoration(
          border: Border.all(color: adaptiveBorderColor),
          borderRadius: widget.options.borderRadius,
        ),
        decoration: BoxDecoration(
          color: primaryColor,
          borderRadius: widget.options.borderRadius!.add(
            // add extra 1 px because border
            const BorderRadius.all(
              Radius.circular(1),
            ),
          ),
        ),
        clipBehavior: Clip.hardEdge,
        child: _view,
      ),
    );

    return turnstileWidget;
  }
}

// ignore: must_be_immutable
class _TurnstileInvisible extends CloudflareTurnstile {
  _TurnstileInvisible.init({
    required super.siteKey,
    super.action,
    super.cData,
    super.baseUrl = 'http://localhost',
    super.onTokenReceived,
    super.onTokenExpired,
    super.onTimeout,
    super.options,
  }) : super(
          controller: TurnstileController(),
        ) {
    _register();
  }

  late web.HTMLDivElement _widget;
  late String _iframeViewType;
  Completer<String?>? _completer;
  Timer? _scriptLoadTimer;
  Timer? _tokenWaitTimer;
  bool _isDisposed = false;

  void _register() {
    _iframeViewType = _createViewType();
    _widget = _buildContainer('cf-turnstile_$_iframeViewType')
      // Off-screen and non-interfering. NOT `display:none`, which would
      // prevent Cloudflare from running the challenge at all.
      ..style.position = 'fixed'
      ..style.bottom = '0'
      ..style.left = '0'
      ..style.width = '0'
      ..style.height = '0'
      ..style.overflow = 'hidden';

    web.document.body?.append(_widget);

    _scriptLoadTimer?.cancel();
    _scriptLoadTimer = Timer(const Duration(milliseconds: 8000), () {
      if (controller?.isWidgetReady != true) {
        onTimeout?.call();
        // Unblock any pending getToken() call - previously this timed out
        // without completing the completer, hanging the returned future.
        _completeToken(null);
      }
    });

    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    try {
      await _ensureTurnstileScriptLoaded();
    } on Object catch (_) {
      if (_isDisposed) return;
      onTimeout?.call();
      _completeToken(null);
      return;
    }
    if (_isDisposed) return;
    _renderOnce();
  }

  void _renderOnce() {
    if (_isDisposed) return;
    final existingId = controller?.widgetId;
    if (existingId != null && existingId.isNotEmpty) return;

    final params = _buildRenderParams(
      siteKey: siteKey,
      options: options,
      action: action,
      cData: cData,
      // Invisible usage never shows widget UI, so keep the widget hidden
      // unless Cloudflare would require interaction.
      appearance: 'interaction-only',
      onToken: ((JSString token) {
        if (_isDisposed) return;
        controller?.token = token.toDart;
        onTokenReceived?.call(token.toDart);
        _completeToken(token.toDart);
      }).toJS,
      // Deliberately returns nothing: Cloudflare then still logs the error
      // code to the browser console (where console-capture tooling like
      // PostHog picks it up) in addition to the completer path here.
      onError: ((JSString code) {
        if (!_isDisposed) {
          final errorCode = int.tryParse(code.toDart) ?? -1;
          final error = TurnstileException.fromCode(errorCode);
          controller?.error = error;
          _completeTokenError(error);
        }
      }).toJS,
      onTokenExpired: (() {
        if (_isDisposed) return;
        onTokenExpired?.call();
        _completeToken(null);
      }).toJS,
      onTimeout: (() {
        if (_isDisposed) return;
        _completeToken(null);
      }).toJS,
      // A hidden widget can never satisfy an interactive challenge; fail
      // fast so callers can fall back to a visible challenge right away
      // instead of waiting for their own timeout.
      onBeforeInteractive: (() {
        if (_isDisposed) return;
        _completeToken(null);
      }).toJS,
    );

    JSString? renderedId;
    try {
      renderedId = _renderTurnstile(_widget, params);
    } on Object catch (_) {
      renderedId = null;
    }

    if (renderedId == null || renderedId.toDart.isEmpty) {
      _completeTokenError(
        const TurnstileException('Failed to render the Turnstile widget.'),
      );
      return;
    }

    controller?.widgetId = renderedId.toDart;
    controller?.isWidgetReady = true;
    _scriptLoadTimer?.cancel();
  }

  /// Completes a pending [getToken]/[refresh] call. Null-safe and
  /// idempotent: safe to call when no call is pending or when the pending
  /// call was already completed by another callback.
  void _completeToken(String? token) {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.complete(token);
    }
  }

  /// Error-completing variant of [_completeToken].
  void _completeTokenError(TurnstileException error) {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  /// Guards a pending token request so the returned future always
  /// completes (with `null`) even if no Turnstile callback ever fires.
  void _armTokenWaitGuard() {
    _tokenWaitTimer?.cancel();
    _tokenWaitTimer = Timer(const Duration(milliseconds: 8000), () {
      _completeToken(null);
    });
  }

  @override
  Future<String?> getToken() async {
    _completer = Completer<String?>();

    if (token != null) {
      await controller?.refreshToken();
    }

    _armTokenWaitGuard();

    return _completer!.future;
  }

  @override
  String? get id => controller?.widgetId;

  @override
  Future<bool> isExpired() {
    return controller!.isExpired();
  }

  @override
  Future<void> refresh({bool forceRefresh = true}) async {
    if (!controller!.isWidgetReady || forceRefresh) {
      await getToken();
    } else if (controller!.isWidgetReady) {
      _completer = Completer<String?>();

      if (token != null && !await controller!.isExpired()) {
        _completeToken(token);
        return;
      }

      _armTokenWaitGuard();
      await controller?.refreshToken();
      await _completer!.future;
    }
  }

  @override
  String? get token => controller?.token;

  @override
  Future<void> dispose() async {
    _isDisposed = true;
    _scriptLoadTimer?.cancel();
    _tokenWaitTimer?.cancel();
    // Unblock any pending getToken() call before tearing down.
    _completeToken(null);
    // Deregister from Cloudflare's runtime BEFORE removing the DOM node,
    // otherwise the runtime keeps tracking an orphaned widget.
    _safeRemoveTurnstileWidget(controller?.widgetId);
    _widget.remove();
  }
}
