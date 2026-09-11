"""Select the test's temporary folder in Super's real X11 native chooser.
No product test hook or page-supplied path is used.
"""
import ctypes as c
import sys,time,os
x=c.CDLL('libX11.so.6');t=c.CDLL('libXtst.so.6');W=c.c_ulong;P=c.c_void_p
x.XOpenDisplay.restype=P;x.XOpenDisplay.argtypes=[c.c_char_p]
x.XDefaultRootWindow.argtypes=[P];x.XDefaultRootWindow.restype=W
x.XQueryTree.argtypes=[P,W,c.POINTER(W),c.POINTER(W),c.POINTER(c.POINTER(W)),c.POINTER(c.c_uint)]
x.XFetchName.argtypes=[P,W,c.POINTER(c.c_char_p)];x.XFree.argtypes=[P]
x.XSetInputFocus.argtypes=[P,W,c.c_int,W];x.XRaiseWindow.argtypes=[P,W]
x.XStringToKeysym.argtypes=[c.c_char_p];x.XStringToKeysym.restype=W
x.XKeysymToKeycode.argtypes=[P,W];x.XKeysymToKeycode.restype=c.c_uint
x.XFlush.argtypes=[P];t.XTestFakeKeyEvent.argtypes=[P,c.c_uint,c.c_int,W]
d=x.XOpenDisplay(None)
if not d: raise RuntimeError('X11 display unavailable')
def find(w):
 name=c.c_char_p();x.XFetchName(d,w,c.byref(name));title=name.value.decode(errors='replace') if name.value else ''
 if name:x.XFree(name)
 if title==os.environ.get('SUPER_CHOOSER_TITLE','Open repository for local development'):return w
 root=W();parent=W();children=c.POINTER(W)();count=c.c_uint()
 if x.XQueryTree(d,w,c.byref(root),c.byref(parent),c.byref(children),c.byref(count)):
  ids=[children[i] for i in range(count.value)]
  if children:x.XFree(children)
  for child in reversed(ids):
   result=find(child)
   if result:return result
 return None
end=time.time()+10;window=None
while time.time()<end:
 window=find(x.XDefaultRootWindow(d))
 if window:break
 time.sleep(.1)
if not window:raise RuntimeError('Super development chooser not found')
# Give the compositor a real pointer activation before keyboard input.
x.XTranslateCoordinates.argtypes=[P,W,W,c.c_int,c.c_int,c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(W)]
t.XTestFakeMotionEvent.argtypes=[P,c.c_int,c.c_int,c.c_int,W]
t.XTestFakeButtonEvent.argtypes=[P,c.c_uint,c.c_int,W]
rx=c.c_int();ry=c.c_int();child=W()
x.XTranslateCoordinates(d,window,x.XDefaultRootWindow(d),500,50,c.byref(rx),c.byref(ry),c.byref(child))
t.XTestFakeMotionEvent(d,-1,rx.value,ry.value,0);t.XTestFakeButtonEvent(d,1,1,0);t.XTestFakeButtonEvent(d,1,0,0);x.XFlush(d);time.sleep(.4)
class Data(c.Union):_fields_=[('b',c.c_char*20),('s',c.c_short*10),('l',c.c_long*5)]
class Client(c.Structure):_fields_=[('type',c.c_int),('serial',W),('send_event',c.c_int),('display',P),('window',W),('message_type',W),('format',c.c_int),('data',Data)]
class Event(c.Union):_fields_=[('client',Client),('pad',c.c_long*24)]
x.XInternAtom.argtypes=[P,c.c_char_p,c.c_int];x.XInternAtom.restype=W
x.XSendEvent.argtypes=[P,W,c.c_int,c.c_long,c.POINTER(Event)]
e=Event();e.client.type=33;e.client.display=d;e.client.window=window;e.client.message_type=x.XInternAtom(d,b'_NET_ACTIVE_WINDOW',0);e.client.format=32;e.client.data.l[0]=2;e.client.data.l[1]=0
x.XSendEvent(d,x.XDefaultRootWindow(d),0,(1<<20)|(1<<19),c.byref(e));x.XFlush(d);time.sleep(.4)
x.XSetInputFocus(d,window,1,0);x.XFlush(d);time.sleep(.4)

def key(name,down):
 code=x.XKeysymToKeycode(d,x.XStringToKeysym(name.encode()));assert code,name;t.XTestFakeKeyEvent(d,code,down,0);x.XFlush(d)
def tap(name):key(name,1);time.sleep(.015);key(name,0);time.sleep(.025)
if len(sys.argv)>2 and sys.argv[1]=='--screenshot':
 import gi
 gi.require_version('Gdk','3.0');gi.require_version('GdkX11','3.0')
 from gi.repository import Gdk,GdkX11
 Gdk.init([]);foreign=GdkX11.X11Window.foreign_new_for_display(Gdk.Display.get_default(),window)
 pix=Gdk.pixbuf_get_from_window(foreign,0,0,foreign.get_width(),foreign.get_height());pix.savev(sys.argv[2],'png',[],[]);sys.exit(0)
if len(sys.argv)>1:
 key('Control_L',1);tap('l');key('Control_L',0);time.sleep(.7)
 import gi
 gi.require_version('Gtk','3.0')
 from gi.repository import Gtk,Gdk
 Gtk.init([])
 clipboard=Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
 previous=clipboard.wait_for_text()
 clipboard.set_text(sys.argv[1],-1)
 key('Control_L',1);tap('a');tap('v');key('Control_L',0)
 end=time.time()+1
 while time.time()<end:
  while Gtk.events_pending():Gtk.main_iteration_do(False)
  time.sleep(.01)
 tap('Return')
 time.sleep(.5)
 if previous is not None:clipboard.set_text(previous,-1);clipboard.store()
else:
 tap('Return');time.sleep(.7);key('Alt_L',1);tap('o');key('Alt_L',0)
