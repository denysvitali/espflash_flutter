# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# usb-serial-for-android uses reflection-free driver lookup, but keep the
# driver classes so R8 can't strip them from the release build.
-keep class com.hoho.android.usbserial.** { *; }
