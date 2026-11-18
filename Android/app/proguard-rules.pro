# Phone Mirroring's server is started by app_process (nothing in the app references it).
-keep class local.islet.link.mirror.Server { public static void main(java.lang.String[]); }
-keep class local.islet.link.mirror.** { *; }
