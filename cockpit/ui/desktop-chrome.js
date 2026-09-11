import { navigate, travel } from './app-shell.js';
export function initDesktopChrome(invoke){
  const $=id=>document.getElementById(id),root=document.documentElement;
  let prefs={left:218,right:260,navHidden:false,activityHidden:false};try{Object.assign(prefs,JSON.parse(localStorage.getItem('super.desktop.layout')||'{}'));}catch{}
  const save=()=>{try{localStorage.setItem('super.desktop.layout',JSON.stringify(prefs));}catch{}};
  function layout(){
    prefs.left=Math.max(160,Math.min(420,Number(prefs.left)||218));prefs.right=Math.max(200,Math.min(480,Number(prefs.right)||260));
    if(innerWidth>1050&&!prefs.activityHidden){const remaining=innerWidth-360-(prefs.navHidden?0:prefs.left);prefs.right=Math.min(prefs.right,Math.max(200,remaining));}
    root.style.setProperty('--rail-width',`${prefs.navHidden?0:prefs.left}px`);root.style.setProperty('--activity-width',`${prefs.activityHidden?0:prefs.right}px`);
    document.body.classList.toggle('nav-collapsed',prefs.navHidden);document.body.classList.toggle('activity-collapsed',prefs.activityHidden);
    $('toggle-sidebar').setAttribute('aria-expanded',String(!prefs.navHidden));
    for(const [id,key] of [['rail-resizer','left'],['activity-resizer','right']])$(id).setAttribute('aria-valuenow',prefs[key]);save();
  }
  $('toggle-sidebar').onclick=()=>{prefs.navHidden=!prefs.navHidden;layout();};
  $('history-back').onclick=()=>travel(-1);$('history-forward').onclick=()=>travel(1);
  document.addEventListener('navigation-history',e=>{$('history-back').disabled=!e.detail.back;$('history-forward').disabled=!e.detail.forward;});
  for(const [id,key,min,max,sign] of [['rail-resizer','left',160,420,1],['activity-resizer','right',200,480,-1]]){
    const handle=$(id);handle.setAttribute('aria-valuemin',min);handle.setAttribute('aria-valuemax',max);let drag;
    handle.onpointerdown=e=>{if(e.button!==0)return;e.preventDefault();drag={x:e.clientX,width:prefs[key]};handle.setPointerCapture(e.pointerId);document.body.classList.add('resizing');};
    handle.onpointermove=e=>{if(!drag)return;prefs[key]=Math.max(min,Math.min(max,drag.width+(e.clientX-drag.x)*sign));layout();};
    handle.onpointerup=handle.onlostpointercapture=()=>{drag=null;document.body.classList.remove('resizing');};
    handle.ondblclick=()=>{prefs[key]=key==='left'?218:260;layout();};
    handle.onkeydown=e=>{if(!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();prefs[key]=e.key==='Home'?min:e.key==='End'?max:prefs[key]+(e.key==='ArrowRight'?10:-10)*sign;layout();};
  }
  function showMessage(title,text){let dialog=$('desktop-help');if(!dialog){dialog=document.createElement('dialog');dialog.id='desktop-help';document.body.append(dialog);}dialog.replaceChildren();const h=document.createElement('h2'),p=document.createElement('p'),b=document.createElement('button');h.textContent=title;p.textContent=text;b.textContent='Done';b.onclick=()=>dialog.close();dialog.append(h,p,b);dialog.showModal();}
  const windowAction=action=>invoke('desktop_window',{action}).catch(()=>showMessage('Window control unavailable','Please use your desktop window controls.'));
  document.querySelectorAll('[data-window-action]').forEach(b=>b.onclick=()=>windowAction(b.dataset.windowAction));
  for(const direction of ['North','South','East','West','NorthEast','NorthWest','SouthEast','SouthWest']){
    const edge=document.createElement('div');edge.dataset.windowResize=direction;edge.className='window-resize-edge edge-'+direction;edge.title='Resize window';
    edge.onpointerdown=e=>{if(e.button!==0)return;e.preventDefault();windowAction('resize-'+direction);};document.body.append(edge);
  }
  $('window-drag').onpointerdown=e=>{if(e.button===0&&e.detail!==2)windowAction('drag');};$('window-drag').ondblclick=()=>windowAction('maximize');
  const botClick=id=>{navigate('bots',true);$(id)?.click();};let previousFocus=null;
  const menus={File:[['New workspace',()=>{navigate('new-workspace',true);document.querySelector('[data-draft="workspace_name"]')?.focus();}],['New conversation',()=>botClick('bot-new')],['Attach files…',()=>botClick('bot-attach')],['Manage connections',()=>botClick('bot-manage')],['Pair a phone…',()=>navigate('mobile',true)]],Edit:[['Undo',()=>edit('undo')],['Redo',()=>edit('redo')],['Select all',()=>edit('selectAll')]],View:[['Toggle sidebar',()=>$('toggle-sidebar').click()],['Toggle activity',()=>{prefs.activityHidden=!prefs.activityHidden;layout();}],['Reset sidebar sizes',()=>{prefs.left=218;prefs.right=260;layout();}],['Find a page…',()=>$('open-navigation').click()]],Help:[['Keyboard shortcuts',()=>showMessage('Keyboard shortcuts','Ctrl K: find a page. Ctrl B: toggle sidebar. Alt Left / Right: back / forward. Focus a sidebar border and use arrow keys to resize. Double-click a border to reset its width.')],['About Super',()=>showMessage('Super','Your local workspace cockpit. Runtime pages show confirmed state. Bot proposals require your review before changing your work.')]]};
  function edit(command){previousFocus?.focus();document.execCommand(command);}
  function closeMenus(){document.querySelectorAll('.desktop-menu').forEach(m=>m.hidden=true);document.querySelectorAll('[data-menu]').forEach(b=>b.setAttribute('aria-expanded','false'));}
  for(const [name,items] of Object.entries(menus)){
    const wrap=document.createElement('div'),button=document.createElement('button'),menu=document.createElement('div');wrap.className='desktop-menu-wrap';button.textContent=name;button.dataset.menu=name;button.setAttribute('aria-haspopup','menu');button.setAttribute('aria-expanded','false');menu.className='desktop-menu';menu.role='menu';menu.hidden=true;
    button.onpointerdown=()=>{if(!document.activeElement.closest('#desktop-menus'))previousFocus=document.activeElement;};
    button.onclick=()=>{const opening=menu.hidden;closeMenus();menu.hidden=!opening;button.setAttribute('aria-expanded',String(opening));};
    button.onkeydown=e=>{if(e.key==='ArrowDown'){e.preventDefault();closeMenus();menu.hidden=false;button.setAttribute('aria-expanded','true');menu.querySelector('button').focus();}};
    for(const [label,run] of items){const item=document.createElement('button');item.textContent=label;item.role='menuitem';item.onclick=()=>{closeMenus();run();};menu.append(item);}
    menu.onkeydown=e=>{const buttons=[...menu.children],i=buttons.indexOf(document.activeElement);if(e.key==='Escape'){closeMenus();button.focus();}if(['ArrowUp','ArrowDown'].includes(e.key)){e.preventDefault();buttons[(i+(e.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length].focus();}};
    wrap.append(button,menu);$('desktop-menus').append(wrap);
  }
  document.addEventListener('pointerdown',e=>{if(!e.target.closest('#desktop-menus'))closeMenus();});
  document.addEventListener('keydown',e=>{if(e.key==='Escape')closeMenus();if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==='b'){e.preventDefault();$('toggle-sidebar').click();}if(e.altKey&&['ArrowLeft','ArrowRight'].includes(e.key)){e.preventDefault();travel(e.key==='ArrowLeft'?-1:1);}});
  window.addEventListener('resize',layout);
  layout();
}
