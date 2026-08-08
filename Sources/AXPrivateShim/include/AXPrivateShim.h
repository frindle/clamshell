// Private ApplicationServices/HIServices function declaration.
//
// _AXUIElementGetWindow has no public header but is exported and widely
// relied on by real window-management tools (Hammerspoon, Rectangle, yabai)
// for exactly the problem it solves here: mapping an AXUIElement to the
// CGWindowID SCShareableContent/CGWindowListCopyWindowInfo use, which the
// public AX API cannot do reliably (see WindowHideSelfTest.swift's "KNOWN
// LIMITATION" comment -- title/frame matching against kAXWindowsAttribute
// does not work for at least Terminal and Finder, confirmed live). Private
// API: verify behavior after every macOS update, same caveat as
// CGVirtualDisplayShim.
#import <ApplicationServices/ApplicationServices.h>

AXError _AXUIElementGetWindow(AXUIElementRef element, CGWindowID *identifier);
