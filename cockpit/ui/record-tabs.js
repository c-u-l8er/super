const selections=new Map();
export function recordTab(key){return selections.get(key)??'overview';}
export function initRecordTabs(){
  document.addEventListener('click',e=>{const button=e.target.closest('[data-record-tab]');if(!button)return;const page=button.closest('.record-page'),key=page.dataset.tabKey,value=button.dataset.recordTab;selections.set(key,value);if(selections.size>128)selections.delete(selections.keys().next().value);for(const tab of page.querySelectorAll('[data-record-tab]')){const selected=tab.dataset.recordTab===value;tab.setAttribute('aria-selected',String(selected));tab.tabIndex=selected?0:-1;}for(const view of page.querySelectorAll('[data-record-view]'))view.hidden=view.dataset.recordView!==value;});
  document.addEventListener('keydown',e=>{const button=e.target.closest('[data-record-tab]');if(!button||!['ArrowLeft','ArrowRight','Home','End'].includes(e.key))return;e.preventDefault();const tabs=[...button.parentElement.querySelectorAll('[data-record-tab]')],index=tabs.indexOf(button),next=e.key==='Home'?0:e.key==='End'?tabs.length-1:(index+(e.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;tabs[next].click();tabs[next].focus();});
}
