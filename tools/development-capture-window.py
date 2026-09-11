"""Capture the native Super window descended from the supplied driver PID."""
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

x.XRaiseWindow.argtypes=[P,W];x.XFlush.argtypes=[P];x.XRaiseWindow(d,w);x.XFlush(d);time.sleep(.8)
import subprocess
subprocess.run(['import','-window',str(w),sys.argv[2]],check=True,timeout=15)
