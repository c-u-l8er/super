"""Drag the corner of the Super process descended from the test driver."""
import ctypes as c,sys,time
from pathlib import Path
parent=int(sys.argv[1]);desc={parent}
for _ in range(8):
 for p in Path('/proc').glob('[0-9]*/stat'):
  try:
   data=p.read_text().rsplit(')',1)[1].split()
   if int(data[1]) in desc:desc.add(int(p.parent.name))
  except (OSError,ValueError):pass
x=c.CDLL('libX11.so.6');t=c.CDLL('libXtst.so.6');P=c.c_void_p;W=c.c_ulong
x.XOpenDisplay.restype=P;x.XOpenDisplay.argtypes=[c.c_char_p];d=x.XOpenDisplay(None)
x.XDefaultRootWindow.argtypes=[P];x.XDefaultRootWindow.restype=W;root=x.XDefaultRootWindow(d)
x.XQueryTree.argtypes=[P,W,c.POINTER(W),c.POINTER(W),c.POINTER(c.POINTER(W)),c.POINTER(c.c_uint)]
x.XFetchName.argtypes=[P,W,c.POINTER(c.c_char_p)];x.XFree.argtypes=[P]
x.XInternAtom.argtypes=[P,c.c_char_p,c.c_int];x.XInternAtom.restype=W
x.XGetWindowProperty.argtypes=[P,W,W,c.c_long,c.c_long,c.c_int,W,c.POINTER(W),c.POINTER(c.c_int),c.POINTER(W),c.POINTER(W),c.POINTER(P)]
x.XGetGeometry.argtypes=[P,W,c.POINTER(W),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_uint),c.POINTER(c.c_uint),c.POINTER(c.c_uint),c.POINTER(c.c_uint)]
pidatom=x.XInternAtom(d,b'_NET_WM_PID',0)
def find(w):
 name=c.c_char_p();x.XFetchName(d,w,c.byref(name));title=name.value.decode(errors='replace') if name.value else '';x.XFree(name)
 if True:
  typ=W();fmt=c.c_int();n=W();left=W();value=P()
  if x.XGetWindowProperty(d,w,pidatom,0,1,0,0,c.byref(typ),c.byref(fmt),c.byref(n),c.byref(left),c.byref(value))==0 and value:
   pid=c.cast(value,c.POINTER(W))[0];x.XFree(value)
   if pid in desc:
    gr=W();xx=c.c_int();yy=c.c_int();ww=c.c_uint();hh=c.c_uint();bb=c.c_uint();dd=c.c_uint()
    x.XGetGeometry(d,w,c.byref(gr),c.byref(xx),c.byref(yy),c.byref(ww),c.byref(hh),c.byref(bb),c.byref(dd))
    if ww.value>400 and hh.value>300:return w
 r=W();p=W();children=c.POINTER(W)();count=c.c_uint()
 if x.XQueryTree(d,w,c.byref(r),c.byref(p),c.byref(children),c.byref(count)):
  ids=[children[i] for i in range(count.value)];x.XFree(children)
  for child in reversed(ids):
   match=find(child)
   if match:return match
w=find(root)
if not w:raise RuntimeError('Test Super window not found')
x.XGetGeometry.argtypes=[P,W,c.POINTER(W),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_uint),c.POINTER(c.c_uint),c.POINTER(c.c_uint),c.POINTER(c.c_uint)]
r=W();gx=c.c_int();gy=c.c_int();width=c.c_uint();height=c.c_uint();border=c.c_uint();depth=c.c_uint()
x.XGetGeometry(d,w,c.byref(r),c.byref(gx),c.byref(gy),c.byref(width),c.byref(height),c.byref(border),c.byref(depth))
x.XTranslateCoordinates.argtypes=[P,W,W,c.c_int,c.c_int,c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(W)]
rx=c.c_int();ry=c.c_int();child=W();x.XTranslateCoordinates(d,w,root,0,0,c.byref(rx),c.byref(ry),c.byref(child))
x.XRaiseWindow.argtypes=[P,W];x.XFlush.argtypes=[P];x.XRaiseWindow(d,w)
t.XTestFakeMotionEvent.argtypes=[P,c.c_int,c.c_int,c.c_int,W];t.XTestFakeButtonEvent.argtypes=[P,c.c_uint,c.c_int,W]
def move(a,b):t.XTestFakeMotionEvent(d,-1,a,b,0);x.XFlush(d)
def press(down):t.XTestFakeButtonEvent(d,1,down,0);x.XFlush(d)
move(rx.value+width.value//2,ry.value+28);press(1);press(0);time.sleep(.3)
class Data(c.Union):_fields_=[('b',c.c_char*20),('s',c.c_short*10),('l',c.c_long*5)]
class Client(c.Structure):_fields_=[('type',c.c_int),('serial',W),('send_event',c.c_int),('display',P),('w',W),('message_type',W),('format',c.c_int),('data',Data)]
class Event(c.Union):_fields_=[('client',Client),('pad',c.c_long*24)]
x.XInternAtom.argtypes=[P,c.c_char_p,c.c_int];x.XInternAtom.restype=W
x.XSendEvent.argtypes=[P,W,c.c_int,c.c_long,c.POINTER(Event)]
e=Event();e.client.type=33;e.client.display=d;e.client.w=w;e.client.message_type=x.XInternAtom(d,b'_NET_ACTIVE_WINDOW',0);e.client.format=32;e.client.data.l[0]=2;e.client.data.l[1]=0
x.XSendEvent(d,x.XDefaultRootWindow(d),0,(1<<20)|(1<<19),c.byref(e));x.XFlush(d);time.sleep(.4)
x.XSetInputFocus.argtypes=[P,W,c.c_int,W];x.XSetInputFocus(d,w,1,0);x.XFlush(d);time.sleep(.4)

# Activation may move the window into the work area. Measure its new origin.
x.XGetGeometry(d,w,c.byref(r),c.byref(gx),c.byref(gy),c.byref(width),c.byref(height),c.byref(border),c.byref(depth))
x.XTranslateCoordinates(d,w,root,0,0,c.byref(rx),c.byref(ry),c.byref(child))
startx=rx.value+width.value-4;starty=ry.value+height.value-4
move(startx,starty);time.sleep(.2)
x.XQueryPointer.argtypes=[P,W,c.POINTER(W),c.POINTER(W),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_int),c.POINTER(c.c_uint)]
pr=W();pc=W();px=c.c_int();py=c.c_int();lx=c.c_int();ly=c.c_int();mask=c.c_uint();x.XQueryPointer(d,root,c.byref(pr),c.byref(pc),c.byref(px),c.byref(py),c.byref(lx),c.byref(ly),c.byref(mask))
print({'pointer':[px.value,py.value],'under_pointer':int(pc.value),'target':int(w)},flush=True)
press(1);time.sleep(.25)
for step in range(1,13):move(startx-step*12,starty-step*8);time.sleep(.03)
press(0);time.sleep(.5)
print({'window':int(w),'x':rx.value,'y':ry.value,'width':width.value,'height':height.value,'start':[startx,starty]})
