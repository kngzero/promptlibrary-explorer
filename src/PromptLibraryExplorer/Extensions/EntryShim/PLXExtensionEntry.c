// Entry-point shim for the SwiftPM-built Quick Look extensions (Extensions/README.md).
//
// The real entry point is Foundation's NSExtensionMain (linker flag -e _NSExtensionMain),
// which reads NSExtensionPrincipalClass from Info.plist.
//
// Why this is C and not Swift: SwiftPM links every executable with
// "-alias _<Target>_main _main", so <Target>_main must exist. If Swift defines it
// (main.swift, @main, or even an @_cdecl function with that name) the compiler emits a
// __swift5_entry section, and ExtensionFoundation then calls that "Swift main" from
// inside NSExtensionMain (the ExtensionKit @main convention) - calling NSExtensionMain
// again, recursing until the stack overflows. A C definition emits no __swift5_entry.
extern int NSExtensionMain(int argc, char *argv[]);

int PLXQuickLookPreview_main(int argc, char *argv[]) { return NSExtensionMain(argc, argv); }
int PLXQuickLookThumbnail_main(int argc, char *argv[]) { return NSExtensionMain(argc, argv); }
