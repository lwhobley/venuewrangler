# R8 / ProGuard rules for release builds (code shrinking + obfuscation).
#
# Flutter, Firebase, Sentry, flutter_secure_storage and the Play libraries ship their own
# consumer rules, so this file only carries what the app itself needs.

# The Flutter engine references Play Core split-install classes for deferred components, which
# this app does not use; without this R8 fails on the missing classes.
-dontwarn com.google.android.play.core.**

# Native bridges are reached by name from Dart method channels.
-keep class com.venuewrangler.app.MainActivity { *; }
-keep class com.venuewrangler.app.PlayIntegrityBridge { *; }
