// Test-only. The test process runs as an ordinary GUI process, so every window a test or the code
// under test shows — makeKeyAndOrderFront, a sheet, a panel, a completion popup — appeared on the
// person's screen, over whatever they were doing. An off-screen origin is no cure: AppKit moves a
// titled window back on screen as it orders it in. So each window is made fully transparent and
// click-through just before it is shown, in the one method every way of showing one goes through.
// The window is otherwise untouched: visible to AppKit, key, laid out and drawn as before.
// SHELLFORGE_TESTS_VISIBLE=1 shows them again, to watch a test.
#import "ShellforgeTestHeadless.h"
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

BOOL ShellforgeTestWindowsHidden(void) {
    static BOOL hidden;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hidden = ![[[NSProcessInfo processInfo] environment][@"SHELLFORGE_TESTS_VISIBLE"] isEqualToString:@"1"];
    });
    return hidden;
}

@implementation NSWindow (ShellforgeTestHeadless)

+ (void)load {
    if (!ShellforgeTestWindowsHidden()) { return; }
    Method original = class_getInstanceMethod(self, @selector(orderWindow:relativeTo:));
    Method hidden = class_getInstanceMethod(self, @selector(shellforgeTest_orderWindow:relativeTo:));
    method_exchangeImplementations(original, hidden);
}

- (void)shellforgeTest_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)otherWindow {
    if (place != NSWindowOut) {
        self.alphaValue = 0;
        self.ignoresMouseEvents = YES;
    }
    // Exchanged: this calls AppKit's own implementation.
    [self shellforgeTest_orderWindow:place relativeTo:otherWindow];
}

@end
