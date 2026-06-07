## 3.6.3
* **Web:** Fixed the Cloudflare script being injected multiple times when widgets raced an in-flight load ("Turnstile already has been loaded"). All widgets now share a single cached, idempotent script load (no `onload=` global), which also fixes widgets failing to render on remount (#39).
* **Web:** Widgets are now deregistered from Cloudflare's runtime via `turnstile.remove()` on dispose, fixing "Cannot find Widget cf-chl-widget-..." and "Turnstile Widget seem to have hung" errors caused by orphaned widgets.
* **Web:** Widget callbacks are passed to `turnstile.render()` as per-instance JS closures instead of shared global function names, so concurrently existing widgets can no longer receive each other's events (a cause of spurious 300xxx errors).
* **Web:** A failed `turnstile.render()` no longer marks the widget as ready (which showed an opaque empty box); it now surfaces a non-retryable error through `onError`.
* **Web:** Invisible `getToken()` can no longer hang forever: timeouts, errors, and disposal complete the pending future, and a hidden widget that would require user interaction now fails fast (`appearance: interaction-only` + `before-interactive-callback`) so callers can fall back to a visible challenge immediately.
* **Web:** The invisible widget's container is now rendered off-screen (0x0, fixed) instead of as a 100%x100% element appended to `<body>`.
* **Web:** Visible widgets only render once their container is attached to the document, preventing blank widgets rendered into detached nodes.

## 3.6.2
* Fixed Windows widget lifecycle issues.
* Fixed Web widget failing to render when navigating away and back.

## 3.6.0
* Added timeout fallback for Cloudflare outage

## 3.5.0
* Added MacOS platform support.

## 3.4.1
* Code optimization and cleanup.

## 3.4.0-beta

* Fixed missing `baseUrl` paramter in the invisible Turnstile widget on web.
* Migrated from the deprecated `js` package to `web` package for improved web compatibility.
* Added Windows platform support.

## 3.2.1

* Updated dependencies to latest version.

## 3.2.0

* Added `onTokenReceived` callback to invisible mode.
* Added `onTokenExpired` callback to invisible mode.

## 3.1.2

* Fixed allow cf to display invalid domain widget.
* Fixed Updatede allowed origins.

## 3.1.1

* Added disabled context menu.
* Fixed avoiding navigation to unwanted urls.

## 3.0.1

* Fixed `forceRefersh` not working for invisible mode.

## 3.0.0

* Added background support for the widget without inserting it into the widget tree.
* Introduced customizable widget border radius.
* Implemented display animations for a smoother user experience.
* Fixed compatibility issues with unsupported platforms.
* Updated README to reflect correct naming conventions for the widget.


## 2.0.3

* Fixed app crashes occurring during CAPTCHA in dialog.
* Fixed `flexible` widget rendering issue on iOS.

## 2.0.1

* Added handle incorrect configuration errors
* Update code documentation

## 2.0.0

* Added support for new `flexible` widget size.
* Added notifications for mode mismatches between the widget and Cloudflare Turnstile dashboard settings.
* Added error callback and token callback to `TurnstileController`.
* Added `TurnstileException` for improved error management.
* Fixed issue when the widget was not displayed on the first build.
* Removed automatic detection of widget mode.
* Updated documentation for clarity and accuracy.

## 1.2.6

* Fixed Turnstile Widget duplication
* Fixed `TurnstileSize.compact` widget rendering issue.

## 1.2.4

* Update minimum supported SDK version.
* Fixed iOS Turnstile challange failure.

## 1.2.3

* Fixed Mobile Turnstile challange returns 401 error.
* Fixed Web `TurnstileMode.auto` not working sometimes.

## 1.2.1

* Added a auto detect widget theme based on device brightnese
* Added handle web resource errors
* Fixed Web `TurnstileMode.auto` failed to detect widget mode

## 1.0.2

* Added a optional `TurnstileMode.auto` property.
* Fixed Android deprecation notes.
* Fixed `TurnstileController.token` reset token when refreshing.

## 0.4.2

* Downgrade SDK version
* Fixed example release build failure

## 0.4.0

* Added a optional `action` property.
* Added a optional `cData` property.

## 0.2.1

* Added a optional `size` property.
* Fixed `TurnstileOptions` issue on invisible widget mode.

## 0.1.1

* Added a optional `retryInterval` property.

## 0.1.0+1

* Minor Changesy.

## 0.0.1

* Initial Release
