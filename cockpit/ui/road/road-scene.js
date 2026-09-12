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
  let phase='driving', animation=null, selected=null, frames=0;
  const materials=new Map();
  function material(color){if(!materials.has(color))materials.set(color,new THREE.MeshBasicMaterial({color}));return materials.get(color);}
  function box(x,y,z,w,h,d,color){const m=new THREE.Mesh(new THREE.BoxGeometry(w,h,d),material(color));
    m.position.set(x,y,z);scene.add(m);return m;}
  box(0,ROAD_Y-2,-1600,180,4,5200,0x191b23);
  for(const side of [-1,1])box(side*91,ROAD_Y,-1600,2,1,5200,0x8c7542);
  for(let i=-4;i<29;i++)box(0,ROAD_Y+1,DASH_0_Z-i*DASH_PITCH,3,1,DASH_LEN,0xf2c14e);
  function gantry(z,title,subtitle){
    for(const side of [-1,1])box(side*205,90,z,10,240,12,0x39404b);
    box(0,213,z,420,10,14,0x2de2e6);
    const c=document.createElement('canvas');c.width=720;c.height=160;
    const g=c.getContext('2d');g.fillStyle='#0a101b';g.fillRect(0,0,720,160);
    g.strokeStyle='#f2c14e';g.lineWidth=6;g.strokeRect(3,3,714,154);
    g.fillStyle='#f2c14e';g.font='bold 42px monospace';g.fillText(title,24,65);
    g.fillStyle='#2de2e6';g.font='26px monospace';g.fillText(subtitle,24,122);
    const texture=new THREE.CanvasTexture(c);texture.colorSpace=THREE.SRGBColorSpace;
    const sign=new THREE.Mesh(new THREE.PlaneGeometry(410,92),new THREE.MeshBasicMaterial({map:texture}));
    sign.position.set(0,264,z+8);scene.add(sign);
  }
  gantry(ENTER_Z,'T&R · ENTRANCE ↑','ComputeDriven · Notes / Digest');
  gantry(exitZ,'EXIT ↓','End of lane · return to entrance');
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
    for(const {mesh,element} of cards.values()){
      const r=rectOf(mesh);
      element.style.left=`${r.x}px`;element.style.top=`${r.y}px`;
      element.style.width=`${r.width}px`;element.style.height=`${r.height}px`;
      element.style.transform='none';element.style.visibility=r.visible?'visible':'hidden';
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
  async function travelTo(z){
    if(phase==='approaching'||phase==='reading'||phase==='returning')return false;
    driving.z=THREE.MathUtils.clamp(z,exitZ-220,startZ);
    const arrived=await animate(driving.clone(),forward,'traveling',600);
    if(arrived)phase='driving';return arrived;
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
        const side=i%2?1:-1,z=DASH_0_Z-(7+Math.floor(i/2)*2)*DASH_PITCH;
        const texture=new THREE.CanvasTexture(element);texture.colorSpace=THREE.SRGBColorSpace;
        const mesh=new THREE.Mesh(new THREE.PlaneGeometry(180,99),new THREE.MeshBasicMaterial({map:texture,side:THREE.DoubleSide}));
        mesh.position.set(side*STAND_X,110,z);mesh.rotation.y=-side*.42;scene.add(mesh);
        const edge=new THREE.LineSegments(new THREE.EdgesGeometry(mesh.geometry),new THREE.LineBasicMaterial({color:0x2de2e6}));mesh.add(edge);
        focus(mesh);
        box(side*STAND_X,15,z,5,90,5,0xa98430);
        cards.set(id,{mesh,element});
      });draw();
    },
    async arrive(id,rect){
      const card=cards.get(id);if(!card)return false;
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
    resize,
    snapshot:()=>({phase,frames,position:camera.position.toArray(),drivingZ:driving.z,
      selected,entranceZ:ENTER_Z,exitZ,readRect:selected?rectOf(cards.get(selected).mesh):null}),
  };
}
