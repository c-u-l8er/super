"""Select the test's temporary folder in Super's real X11 native chooser.
No product test hook or page-supplied path is used.
"""
import ctypes as c
import sys,time,os
from pathlib import Path
parent=int(sys.argv[1]);desc={parent}
for _ in range(8):
 for p in Path("/proc").glob("[0-9]*/stat"):
  try:
   data=p.read_text().rsplit(")",1)[1].split()
   if int(data[1]) in desc:desc.add(int(p.parent.name))
  except (OSError,ValueError):pass
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
x.XInternAtom.argtypes=[P,c.c_char_p,c.c_int];x.XInternAtom.restype=W
x.XGetWindowProperty.argtypes=[P,W,W,c.c_long,c.c_long,c.c_int,W,c.POINTER(W),c.POINTER(c.c_int),c.POINTER(W),c.POINTER(W),c.POINTER(P)]
pidatom=x.XInternAtom(d,b'_NET_WM_PID',0)
def owned(w):
 typ=W();fmt=c.c_int();n=W();left=W();value=P()
 if x.XGetWindowProperty(d,w,pidatom,0,1,0,0,c.byref(typ),c.byref(fmt),c.byref(n),c.byref(left),c.byref(value))==0 and value:
  pid=c.cast(value,c.POINTER(W))[0];x.XFree(value)
  return pid in desc
 return False
def find(w):
 name=c.c_char_p();x.XFetchName(d,w,c.byref(name));title=name.value.decode(errors='replace') if name.value else ''
 if name:x.XFree(name)
 if title==os.environ.get('SUPER_CHOOSER_TITLE','Open repository for local development') and owned(w):return w
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

x.XTranslateCoordinates.argtypes=[P,W,W,c.c_int,c.c_int,c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(W)]
x.XGetGeometry.argtypes=[P,W,c.POINTER(W),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_uint),c.POINTER(c.c_uint),c.POINTER(c.c_uint),c.POINTER(c.c_uint)]
t.XTestFakeMotionEvent.argtypes=[P,c.c_int,c.c_int,c.c_int,W]
t.XTestFakeButtonEvent.argtypes=[P,c.c_uint,c.c_int,W]
root=W();gx=c.c_int();gy=c.c_int();width=c.c_uint();height=c.c_uint();border=c.c_uint();depth=c.c_uint()
if not x.XGetGeometry(d,window,c.byref(root),c.byref(gx),c.byref(gy),c.byref(width),c.byref(height),c.byref(border),c.byref(depth)):raise RuntimeError('Chooser geometry unavailable')
rx=c.c_int();ry=c.c_int();child=W()
x.XTranslateCoordinates(d,window,x.XDefaultRootWindow(d),int(width.value*.87),int(height.value*.08),c.byref(rx),c.byref(ry),c.byref(child))
x.XRaiseWindow(d,window);x.XSetInputFocus(d,window,1,0);x.XFlush(d);time.sleep(.4)
if len(sys.argv)==2:
 t.XTestFakeMotionEvent(d,-1,rx.value,ry.value,0);x.XFlush(d);time.sleep(.1)
 t.XTestFakeButtonEvent(d,1,1,0);x.XFlush(d);time.sleep(.1);t.XTestFakeButtonEvent(d,1,0,0);x.XFlush(d);time.sleep(.5)
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

if len(sys.argv)>2:
 path=sys.argv[2]
 if not path.isascii():raise RuntimeError('Test chooser paths must be ASCII')
 key('Control_L',1);tap('l');key('Control_L',0);time.sleep(.2)
 key('Control_L',1);tap('a');key('Control_L',0)
 names={'/':'slash','-':'minus','_':'underscore','.':'period',' ':'space'}
 for char in path:
  shift=char.isupper() or char=='_'
  if shift:key('Shift_L',1)
  tap(names.get(char,char))
  if shift:key('Shift_L',0)
 if os.environ.get('SUPER_CHOOSER_DEBUG'):
  import subprocess
  subprocess.run(['import','-window',str(window),os.environ['SUPER_CHOOSER_DEBUG']],check=True,timeout=10)
 # Activate the dialog button, not the location entry. Return in the entry
 # navigates into the selected child (often .git) instead of choosing this folder.
 x.XTranslateCoordinates(d,window,x.XDefaultRootWindow(d),int(width.value*.87),height.value-22,c.byref(rx),c.byref(ry),c.byref(child))
 t.XTestFakeMotionEvent(d,-1,rx.value,ry.value,0);x.XFlush(d);time.sleep(.1)
 t.XTestFakeButtonEvent(d,1,1,0);x.XFlush(d);time.sleep(.1);t.XTestFakeButtonEvent(d,1,0,0);x.XFlush(d)
else:tap('Return')
time.sleep(.6)
deadline=time.time()+5
while find(x.XDefaultRootWindow(d)) and time.time()<deadline:time.sleep(.1)
if find(x.XDefaultRootWindow(d)):raise RuntimeError('Test chooser did not confirm the requested folder')
print('Confirmed test chooser',window,'size',width.value,height.value,'root point',rx.value,ry.value)
