/* Ask the window manager to close ONE test-owned native window, normally.
 * WebDriver closes a browsing context, which is a different lifecycle. */
#include <X11/Xlib.h>
#include <stdlib.h>
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  Display *display = XOpenDisplay(NULL);
  if (!display) return 3;
  XEvent event = {0};
  event.xclient.type = ClientMessage;
  event.xclient.window = strtoul(argv[1], NULL, 16);
  event.xclient.message_type = XInternAtom(display, "_NET_CLOSE_WINDOW", False);
  event.xclient.format = 32;
  event.xclient.data.l[0] = CurrentTime;
  event.xclient.data.l[1] = 2;
  int sent = XSendEvent(display, DefaultRootWindow(display), False,
      SubstructureRedirectMask | SubstructureNotifyMask, &event);
  XFlush(display);
  XCloseDisplay(display);
  return sent ? 0 : 4;
}
