import * as THREE from './vendor/three.module.js';
import {ROAD_FOV, ROAD_CAMERA_Y, ROAD_Y, STAND_X, ENTER_Z, ENTER_VIEW,
  DASH_0_Z, DASH_PITCH, DASH_LEN} from './road-geometry.js';

// Same forward axis, dash grid and front-normal arrival as m2/travel.js.
// These textures are published sign faces. No live webview pixels are read.
export function createRoadScene(canvas) {
  const renderer=new THREE.WebGLRenderer({canvas,antialias:true,alpha:false});
  renderer.setPixelRatio(Math.min(devicePixelRatio,2));
  renderer.setClearColor(0x03040a);
  const scene=new THREE.Scene();
  scene.fog=new THREE.Fog(0x03040a,3000,6000);
  const camera=new THREE.PerspectiveCamera(ROAD_FOV,1,1,6000);
  const startZ=ENTER_Z+ENTER_VIEW, exitZ=DASH_0_Z-18*DASH_PITCH;
  const driving=new THREE.Vector3(0,ROAD_CAMERA_Y,startZ);
  camera.position.copy(driving);
  const forward=new THREE.Quaternion();
  const cards=new Map();
  const lanes=[{id:'documents',name:'Documents',x:0,package:'notes'},
    {id:'summaries',name:'Summaries',x:1200,package:'digest'}];
  let lane=0,changingLane=false;
  let phase='driving', animation=null, selected=null, frames=0;
  const materials=new Map();
  function material(color){if(!materials.has(color))materials.set(color,new THREE.MeshBasicMaterial({color}));return materials.get(color);}
  function box(x,y,z,w,h,d,color){const m=new THREE.Mesh(new THREE.BoxGeometry(w,h,d),material(color));
    m.position.set(x,y,z);scene.add(m);return m;}
  function gantry(x,z,title,subtitle){
    for(const side of [-1,1])box(x+side*205,90,z,10,240,12,0x39404b);
    box(x,213,z,420,10,14,0x2de2e6);
    const c=document.createElement('canvas');c.width=720;c.height=160;
    const g=c.getContext('2d');g.fillStyle='#0a101b';g.fillRect(0,0,720,160);
    g.strokeStyle='#f2c14e';g.lineWidth=6;g.strokeRect(3,3,714,154);
    g.fillStyle='#f2c14e';g.font='bold 42px monospace';g.fillText(title,24,65);
    g.fillStyle='#2de2e6';g.font='26px monospace';g.fillText(subtitle,24,122);
    const texture=new THREE.CanvasTexture(c);texture.colorSpace=THREE.SRGBColorSpace;
    const sign=new THREE.Mesh(new THREE.PlaneGeometry(410,92),new THREE.MeshBasicMaterial({map:texture}));
    sign.position.set(x,264,z+8);scene.add(sign);
  }
  for(const l of lanes){
    box(l.x,ROAD_Y-2,-1230,180,4,3620,0x191b23);
    for(const side of [-1,1])box(l.x+side*91,ROAD_Y,-1230,2,1,3620,0x8c7542);
    for(let i=-2;i<19;i++)box(l.x,ROAD_Y+1,DASH_0_Z-i*DASH_PITCH,3,1,DASH_LEN,0xf2c14e);
    gantry(l.x,ENTER_Z,`${l.name.toUpperCase()} ↑`,'T&R · ENTRANCE');
    gantry(l.x,exitZ,'EXIT · CONNECTING RAMP',`To ${lanes.find(other=>other!==l).name}`);
  }
  // Camera and pavement share this curve: switching lanes is a continuous
  // exit/return/entrance route, not a camera teleport across unrelated roads.
  const ramps=lanes.map((l,i)=>{
    const dest=lanes[1-i],mid=i===0?480:720;
    const curve=new THREE.CatmullRomCurve3([
      [l.x,exitZ],[l.x,exitZ-300],[mid,exitZ-550],[mid,exitZ-150],
      [mid,startZ+100],[dest.x,startZ+350],[dest.x,startZ],[dest.x,ENTER_Z],
    ].map(([x,z])=>new THREE.Vector3(x,ROAD_CAMERA_Y,z)));
    const positions=[],indices=[];
    for(let n=0;n<=240;n++){
      const p=curve.getPointAt(n/240),t=curve.getTangentAt(n/240);
      const side=new THREE.Vector3(-t.z,0,t.x).normalize();
      for(const s of [-1,1])positions.push(p.x+side.x*55*s,ROAD_Y,p.z+side.z*55*s);
      if(n<240){const a=n*2;indices.push(a,a+2,a+1,a+1,a+2,a+3);}
    }
    const geometry=new THREE.BufferGeometry();
    geometry.setAttribute('position',new THREE.Float32BufferAttribute(positions,3));geometry.setIndex(indices);
    const pavement=new THREE.Mesh(geometry,new THREE.MeshBasicMaterial({color:0x242932,side:THREE.DoubleSide}));scene.add(pavement);
    const line=new THREE.BufferGeometry().setFromPoints(curve.getSpacedPoints(160).map(p=>new THREE.Vector3(p.x,ROAD_Y+1,p.z)));
    scene.add(new THREE.Line(line,new THREE.LineBasicMaterial({color:0xf2c14e})));
    return curve;
  });
  function rectOf(mesh){
    mesh.updateMatrixWorld();camera.updateMatrixWorld();
    const points=[[-90,-49.5],[90,-49.5],[90,49.5],[-90,49.5]].map(([x,y])=>
      new THREE.Vector3(x,y,0).applyMatrix4(mesh.matrixWorld).project(camera));
    const width=canvas.clientWidth,height=canvas.clientHeight;
    return {x:(Math.min(...points.map(p=>p.x))+1)*width/2,
      y:(1-Math.max(...points.map(p=>p.y)))*height/2,
      width:(Math.max(...points.map(p=>p.x))-Math.min(...points.map(p=>p.x)))*width/2,
      height:(Math.max(...points.map(p=>p.y))-Math.min(...points.map(p=>p.y)))*height/2,
      visible:points.every(p=>p.z<1&&p.z>-1)};
  }
  function draw(){
    camera.updateMatrixWorld();
    renderer.render(scene,camera);frames++;
    for(const {mesh,element,lane:cardLane} of cards.values()){
      const r=rectOf(mesh);
      element.style.left=`${r.x}px`;element.style.top=`${r.y}px`;
      element.style.width=`${r.width}px`;element.style.height=`${r.height}px`;
      element.style.transform='none';element.style.visibility=r.visible&&cardLane===lane&&phase!=='ramp'?'visible':'hidden';
    }
  }
  function animate(position,quaternion,nextPhase,duration=850,scaleTo=1){
    if(animation){cancelAnimationFrame(animation.frame);animation.resolve(false);animation=null;}
    const from=camera.position.clone(),rotation=camera.quaternion.clone();
    const mesh=selected&&cards.get(selected)?.mesh,scaleFrom=mesh?.scale.y??1;
    phase=nextPhase;
    return new Promise(resolve=>{
      const start=performance.now();animation={resolve,frame:null};
      const tick=now=>{
        const t=Math.min(1,(now-start)/duration),s=t*t*(3-2*t);
        camera.position.lerpVectors(from,position,s);camera.quaternion.slerpQuaternions(rotation,quaternion,s);
        if(mesh)mesh.scale.y=scaleFrom+(scaleTo-scaleFrom)*s;
        draw();
        if(t<1)animation.frame=requestAnimationFrame(tick);
        else{animation=null;resolve(true);}
      };animation.frame=requestAnimationFrame(tick);
    });
  }
  async function travelTo(z,internal=false){
    if(changingLane&&!internal)return false;
    if(!['driving','traveling'].includes(phase))return false;
    driving.z=THREE.MathUtils.clamp(z,exitZ-220,startZ);
    const arrived=await animate(driving.clone(),forward,'traveling',600);
    if(arrived)phase='driving';return arrived;
  }
  async function switchLane(id){
    const target=lanes.findIndex(l=>l.id===id);if(target<0)return false;
    if(changingLane||!['driving','traveling'].includes(phase))return false;
    if(target===lane)return true;
    changingLane=true;
    await travelTo(exitZ,true);
    phase='ramp';
    const curve=ramps[lane];
    await new Promise(resolve=>{
      const start=performance.now(),up=new THREE.Vector3(0,1,0),matrix=new THREE.Matrix4();
      const tick=now=>{
        const t=Math.min(1,(now-start)/3200),s=t*t*(3-2*t);
        const p=curve.getPointAt(s),tangent=curve.getTangentAt(s);
        camera.position.copy(p);matrix.lookAt(p,p.clone().add(tangent),up);
        camera.quaternion.setFromRotationMatrix(matrix);draw();
        if(t<1)requestAnimationFrame(tick);else resolve();
      };requestAnimationFrame(tick);
    });
    lane=target;driving.set(lanes[lane].x,ROAD_CAMERA_Y,ENTER_Z);phase='driving';
    await travelTo(DASH_0_Z-4*DASH_PITCH,true);changingLane=false;
    canvas.dispatchEvent(new CustomEvent('lanechange',{detail:lanes[lane]}));return true;
  }
  function resize(){
    const w=canvas.clientWidth,h=canvas.clientHeight;
    renderer.setPixelRatio(Math.min(devicePixelRatio,2));
    renderer.setSize(w,h,false);camera.aspect=w/h;camera.updateProjectionMatrix();draw();
  }
  resize();
  return {
    setSigns(elements){
      // Canvas elements remain accessible hit targets for the texture planes.
      // Rebind after demotion, keeping the same world positions and GPU objects.
      elements.forEach((element,i)=>{
        const id=element.id.replace(/^sign-/,''),existing=cards.get(id);
        const focus=mesh=>{
          element.onfocus=()=>{mesh.children[0].material.color.setHex(0xf2c14e);draw();};
          element.onblur=()=>{mesh.children[0].material.color.setHex(0x2de2e6);draw();};
        };
        if(existing){existing.element=element;existing.mesh.material.map.image=element;existing.mesh.material.map.needsUpdate=true;focus(existing.mesh);return;}
        const cardLane=Math.max(0,lanes.findIndex(l=>l.package===id));
        const side=-1,z=DASH_0_Z-(id==='super'?4:7)*DASH_PITCH,x=lanes[cardLane].x+side*STAND_X;
        const texture=new THREE.CanvasTexture(element);texture.colorSpace=THREE.SRGBColorSpace;
        const mesh=new THREE.Mesh(new THREE.PlaneGeometry(180,99),new THREE.MeshBasicMaterial({map:texture,side:THREE.DoubleSide}));
        mesh.position.set(x,110,z);mesh.rotation.y=-side*.42;scene.add(mesh);
        const edge=new THREE.LineSegments(new THREE.EdgesGeometry(mesh.geometry),new THREE.LineBasicMaterial({color:0x2de2e6}));mesh.add(edge);
        focus(mesh);
        box(x,15,z,5,90,5,0xa98430);
        cards.set(id,{mesh,element,lane:cardLane});
      });draw();
    },
    async arrive(id,rect){
      const card=cards.get(id);if(!card)return false;
      if(changingLane||!['driving','traveling'].includes(phase))return false;
      if(card.lane!==lane&&!await switchLane(lanes[card.lane].id))return false;
      if(phase==='traveling')driving.copy(camera.position);
      selected=id;
      const normal=new THREE.Vector3(0,0,1).applyQuaternion(card.mesh.quaternion);
      const height=180*rect.height/rect.width;
      const distance=height/2/(Math.tan(THREE.MathUtils.degToRad(ROAD_FOV/2))*(rect.height/canvas.clientHeight));
      const pos=card.mesh.position.clone().addScaledVector(normal,distance);
      const q=card.mesh.quaternion.clone();
      const done=await animate(pos,q,'approaching',850,height/99);
      if(done)phase='reading';return done;
    },
    async leave(){
      if(phase==='driving'||phase==='traveling')return true;
      const done=await animate(driving.clone(),forward,'returning',700,1);
      if(done){phase='driving';selected=null;}return done;
    },
    drive:delta=>travelTo(driving.z-delta),
    enter:()=>travelTo(DASH_0_Z-4*DASH_PITCH),
    exit:()=>travelTo(exitZ-220),
    home:()=>travelTo(startZ),
    switchLane,
    resize,
    snapshot:()=>({phase,frames,position:camera.position.toArray(),drivingZ:driving.z,
      lane:lanes[lane].id,lanes:lanes.map(l=>({id:l.id,name:l.name,package:l.package})),
      selected,entranceZ:ENTER_Z,exitZ,readRect:selected?rectOf(cards.get(selected).mesh):null}),
  };
}
