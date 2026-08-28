"""Release-stage preview renderer: regenerates preview/hero-light-preview.png
   from proof/latest.json and writes preview/preview-meta.json so
   check-preview.mjs can hard-fail the release if the image's figures ever
   diverge from the artifact. Paths resolve from the repo root."""
import json as _json
from pathlib import Path as _P
# The site is what gets deployed, so its assets live under `site/`.
_BASE = _P(__file__).resolve().parent.parent / 'site'
import numpy as np, math
from PIL import Image

W,H = 1500,1130
SB = 1046
SL,ST,SW = 90,470,1320
BX, CY = SL+SW*0.56, ST
Y,X = np.mgrid[0:H,0:W].astype(np.float32)

def stops_interp(u, stops):           # u in [0,1] → piecewise-linear through stops
    xs = np.array([s[0] for s in stops],np.float32); ys=np.array([s[1] for s in stops],np.float32)
    return np.interp(u, xs, ys)

def render(nR, nH, nV, grain, out):
    buf = np.zeros((H,W,3), np.float32)
    buf[:] = np.array([5,7,12],np.float32)/255
    def q(a):                          # 8-bit additive quantization each pass
        return np.round(a*255)/255
    def add(col,a):
        buf[:] = q(buf + np.array(col,np.float32)/255*np.clip(a,0,None)[...,None])
    def soft(x,y,rx,ry,col,a,p,clipy=None):
        r=np.sqrt(((X-x)/rx)**2+((Y-y)/ry)**2)
        st=[(i/nR,a*max(0,1-i/nR)**p) for i in range(nR+1)]
        f=stops_interp(np.clip(r,0,1),st)
        if clipy is not None: f=np.where(Y<clipy,f,0)
        add(col,f)
    def strip(sig,col,aT,aB):
        stH=[(i/nH,math.exp(-(((i/nH)-.5)*6*sig)**2/(2*sig*sig))) for i in range(nH+1)]
        g=stops_interp(np.clip((X-BX)/(6*sig)+.5,0,1),stH)
        stV=[(i/nV,aT+(aB-aT)*(i/nV)**1.1) for i in range(nV+1)]
        va=stops_interp(np.clip(Y/CY,0,1),stV); va=np.where(Y<CY,va,0)
        add(col,g*va)
    # fog with envelope built from stops too
    rng=np.random.default_rng(3); fog=np.zeros((H,W),np.float32)
    for _ in range(220):
        cx,cy2,rr=rng.uniform(0,W),rng.uniform(0,CY),rng.uniform(70,220)
        d=np.sqrt((X-cx)**2+(Y-cy2)**2)/rr
        fog+=np.clip(1-d,0,1)**3*rng.uniform(.10,.24)
    stV=[(i/nV,min(max((i/nV-.15)/.85,0),1)**1.5*min(max((1-i/nV)/.10,0),1)**1.2) for i in range(nV+1)]
    vert=stops_interp(np.clip(Y/CY,0,1),stV); vert=np.where(Y<CY,vert,0)
    sig=SW*.38
    stH2=[(i/nH,.35+.65*math.exp(-((i/nH*W-BX)**2)/(2*sig*sig))) for i in range(nH+1)]
    horiz=stops_interp(X/W,stH2)
    add((150,172,210),fog*vert*horiz)
    soft(BX,CY*.55,420,CY*.80,(46,84,170),.16,2.0)
    soft(BX,-10,90,70,(140,180,255),.25,1.8)
    strip(100,(38,96,210),.06,.22); strip(52,(74,146,255),.10,.36)
    strip(22,(150,196,255),.16,.58); strip(6,(240,248,255),.22,.95)
    soft(BX,CY-90,180,260,(60,120,235),.14,2.0)
    soft(BX,CY-34,120,170,(74,146,255),.20,1.8)
    soft(BX,CY-8,240,90,(130,185,255),.26,1.8)
    soft(BX,CY-2,420,54,(200,226,255),.38,1.7,CY+2)
    soft(BX,CY-2,900,30,(140,190,255),.16,1.7,CY+2)
    soft(BX,CY-2,110,26,(255,196,140),.50,1.6,CY+2)
    soft(BX,CY-2,40,12,(255,238,214),.70,1.5,CY+2)
    L,Rr=SL,SL+SW
    soft(Rr+3,CY+16,26, 96,(200,228,255),.34,1.6)
    soft(Rr+5,CY+70,40,240,(110,170,255),.20,1.9)
    soft(Rr+6,CY+210,30,300,(90,150,240),.10,2.0)
    soft(L-3,CY+16,26, 96,(200,228,255),.26,1.6)
    soft(L-5,CY+70,40,240,(110,170,255),.15,1.9)
    soft(L-6,CY+210,30,300,(90,150,240),.08,2.0)
    soft(Rr,CY+2,60,40,(255,214,168),.16,1.6)
    soft(L,CY+2,60,40,(255,214,168),.12,1.6)
    midY,half=(CY+SB)/2,(SB-CY)*.5
    soft(Rr+6,midY+60,34,half,(100,190,255),.12,2.0)
    soft(Rr+6,SB-20,42,150,(110,205,255),.18,1.8)
    soft(L-6,midY+60,34,half,(150,150,210),.10,2.0)
    soft(L-6,SB-30,48,180,(244,140,66),.20,1.8)
    soft(L+SW*.16,SB+8,300,84,(244,132,60),.22,1.8)
    soft(L-6,SB+2,90,70,(244,132,60),.24,1.6)
    soft(Rr-SW*.10,SB+8,260,74,(110,200,255),.18,1.8)
    soft(Rr+6,SB+2,80,64,(120,205,255),.20,1.6)
    if grain:
        g=(np.random.default_rng(1).standard_normal((H,W))*0.006).astype(np.float32)
        g=np.where(Y<CY+2,g,0); buf+= g[...,None]
    m=(Y>=CY)&(Y<=SB)&(X>=SL)&(X<=SL+SW)
    for c in range(3): buf[...,c][m]=np.array([11,16,25],np.float32)[c]/255
    fall=np.clip(1-np.abs(X-BX)/(SW*.55),0,1)**1.1
    band=((Y>=CY)&(Y<CY+2)&(X>=SL)&(X<=SL+SW)).astype(np.float32)
    add((214,236,255),band*fall*.95)
    STH=H-CY
    vt=np.clip((Y-CY)/(STH*.74),0,1)
    prof=np.where(vt<.30/.74, .85+(.30-vt*.74)/.30*0, .0)   # placeholder
    prof=np.interp(vt,[0,.30/.74,.55/.74,1],[.85,.30,.08,0]).astype(np.float32)
    warmL=np.interp(np.clip((Y-CY)/(SB-CY),0,1),[0,.6,1],[0,0,1]).astype(np.float32)
    for ex,sc_,wc in [(SL+SW,1.0,(120,205,255)),(SL,0.82,(244,140,66))]:
        line=((np.abs(X-ex)<1.2)&(Y>=CY)&(Y<=SB)).astype(np.float32)
        pr=np.interp(np.clip((Y-CY)/(SB-CY),0,1),[0,.28,.60,1],[.85,.30,.16,.45]).astype(np.float32)
        add((200,228,255),line*pr*(1-warmL)*sc_)
        add(wc,line*pr*warmL*sc_)
    bl=((np.abs(Y-SB)<1.2)&(X>=SL)&(X<=SL+SW)).astype(np.float32)
    bt=np.interp(X,[SL,SL+SW*.5,SL+SW],[.50,.20,.42]).astype(np.float32)
    add((244,140,66),bl*bt*np.clip(1-(X-SL)/(SW*.6),0,1))
    add((120,205,255),bl*bt*np.clip((X-SL-SW*.4)/(SW*.6),0,1))
    Image.fromarray((np.clip(buf,0,1)*255).astype(np.uint8)).save(out)

render(24,32,24, True, str(_BASE/'preview/.wrap.tmp.png'))
print('ok')

# ---------- share/static preview: the UI must be identifiable as Super ----------
def with_ui(src=str(_BASE/'preview/.wrap.tmp.png'), out=str(_BASE/'preview/hero-light-preview.png')):
    import json
    from PIL import ImageDraw, ImageFont
    P = json.load(open(_BASE/'proof/latest.json'))
    t,r,g = P['totals'], P['run'], P['gates']
    frac = f"{t['passed']}/{t['attempted']}"
    img = Image.open(src).convert('RGB'); d = ImageDraw.Draw(img)
    def F(sz, bold=False):
        try: return ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono'+('-Bold' if bold else '')+'.ttf', sz)
        except: return ImageFont.load_default()
    INK=(237,241,249); MUT=(147,161,187); DIM=(94,108,134); OK=(70,211,154)
    ICE=(143,184,232); VIO=(161,143,255); WRN=(240,180,76); HAIR=(38,48,66); PAN=(14,21,36)
    L,T,Rt = SL, CY, SL+SW
    # frame bar
    d.text((L+18,T+9), "Super (CD)", font=F(15,True), fill=INK)
    d.text((L+130,T+11), "workspace/trvm", font=F(13), fill=MUT)
    d.text((L+310,T+11), f"gates {frac}", font=F(13), fill=OK)
    d.text((L+430,T+11), f"cert ×{r['cert_streak']}", font=F(13), fill=MUT)
    d.text((Rt-52,T+11), "⌘K", font=F(13), fill=DIM)
    d.line([(L,T+34),(Rt,T+34)], fill=HAIR, width=1)
    # rail
    RX=L+170; d.line([(RX,T+34),(RX,H)], fill=HAIR, width=1)
    tree=["WorkspaceSupervisor","├─ GoalServer","├─ EvidenceLedger","├─ ObligationRegistry",
          "├─ LaneSupervisor","│  ├─ lane-a","│  ├─ lane-b","│  └─ lane-c","└─ Fleet/Presence"]
    for i,ln in enumerate(tree):
        d.text((L+14,T+52+i*24), ln, font=F(12), fill=(ICE if 'LaneSup' in ln else DIM))
    # side col
    SX=Rt-200; d.line([(SX,T+34),(SX,H)], fill=HAIR, width=1)
    d.text((SX+16,T+52), "FLEET", font=F(10), fill=DIM)
    for i,(n,p_) in enumerate([("travis-desktop","41%"),("ms02","66%"),("gpu01","12%"),("cd-west ☁","23%"),("laptop","asleep")]):
        d.text((SX+16,T+74+i*22), n, font=F(12), fill=(VIO if '☁' in n else MUT))
        d.text((Rt-16-len(p_)*7,T+74+i*22), p_, font=F(12), fill=DIM)
    d.text((SX+16,T+196), "RECEIPTS", font=F(10), fill=DIM)
    for i,(k,v) in enumerate([("negative",g['negative_battery']),("film",g['semantic_film']),("bridge",g['cross_plane_bridge'])]):
        d.text((SX+16,T+218+i*22), f"{k} {v} ✓", font=F(12), fill=OK)
    # main: goal card
    MX,MW = RX+22, SX-RX-44
    d.rounded_rectangle([MX,T+52,MX+MW,T+150], 10, outline=(58,74,104), width=1, fill=PAN)
    d.text((MX+16,T+66), "GOAL · EMISSION_CONFORMANCE-v1", font=F(14,True), fill=INK)
    d.text((MX+16,T+90), "Seal the argument boundary. Merge waits on obligations, not on optimism.", font=F(11), fill=MUT)
    for i,(c,col) in enumerate([("spec ✓",VIO),("in_tree ✓",ICE),("live_local ✓",OK),("live_deployed —",WRN),("external —",DIM)]):
        x=MX+16+i*118
        d.rounded_rectangle([x,T+114,x+106,T+134], 4, outline=col, width=1)
        d.text((x+8,T+118), c, font=F(10), fill=col)
    # lanes
    lanes=[("lane-a","kestrel · claude-code","LOCAL · travis-desktop",OK,.62),
           ("lane-b","magpie · codex","FLEET · ms02",ICE,.84),
           ("browser-research","authority: net.allowlist","CLOUD · cd-west",VIO,.23)]
    for i,(idn,mid,pl,pc,bw) in enumerate(lanes):
        y=T+166+i*46
        d.rounded_rectangle([MX,y,MX+MW,y+38], 8, outline=HAIR, width=1)
        d.ellipse([MX+14,y+15,MX+22,y+23], fill=OK)
        d.text((MX+34,y+11), idn, font=F(12,True), fill=INK)
        d.text((MX+190,y+12), mid, font=F(11), fill=MUT)
        d.rounded_rectangle([MX+MW-320,y+9,MX+MW-140,y+29], 4, outline=pc, width=1)
        d.text((MX+MW-312,y+13), pl, font=F(10), fill=pc)
        d.rectangle([MX+MW-120,y+17,MX+MW-20,y+21], fill=(40,52,74))
        d.rectangle([MX+MW-120,y+17,MX+MW-120+int(100*bw),y+21], fill=ICE)
    # evidence strip
    y=T+312; d.line([(MX,y),(MX+MW,y)], fill=HAIR, width=1)
    d.text((MX,y+12), "claim  overflow refuses as film-budget-invalid — established in_tree", font=F(11), fill=MUT)
    d.text((MX,y+34), "obligation  confirm negative/invalid split before merge · 1 open", font=F(11), fill=WRN)
    img.save(out)

with_ui()
_p=_json.load(open(_BASE/'proof/latest.json'))
_meta={"source_sha256":_p["sha256"],
       "frac":f"{_p['totals']['passed']}/{_p['totals']['attempted']}",
       "cert_streak":_p["run"]["cert_streak"]}
(_BASE/'preview/preview-meta.json').write_text(_json.dumps(_meta,indent=2))
(_BASE/'preview/.wrap.tmp.png').unlink(missing_ok=True)
print('preview rendered from artifact ·', _meta["frac"], '· ×'+str(_meta["cert_streak"]))
