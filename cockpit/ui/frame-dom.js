/* Reconcile one complete frame render against the displayed DOM. Runtime facts
 * still come only from the new render. Stable controls are not detached merely
 * because another frame arrived between pointerdown and pointerup. */
function key(node) {
  if (node.nodeType !== 1) return null;
  const d = node.dataset;
  if (node.id) return `id:${node.id}`;
  for (const name of ['screen', 'detail', 'id', 'draft', 'nav', 'hostAction', 'intentForm']) {
    if (d[name] !== undefined) return `${node.tagName}:${name}:${d[name]}`;
  }
  if (d.intent !== undefined) return `intent:${d.intent}:${d.args ?? ''}`;
  return null;
}
function compatible(a, b) {
  return a.nodeType === b.nodeType && (a.nodeType !== 1 || a.tagName === b.tagName) && key(a) === key(b);
}
function update(current, planned) {
  if (current.nodeType !== 1) {
    if (current.nodeValue !== planned.nodeValue) current.nodeValue = planned.nodeValue;
    return;
  }
  const formValue = 'value' in planned ? planned.value : undefined;
  for (const {name} of [...current.attributes]) if (!planned.hasAttribute(name)) current.removeAttribute(name);
  for (const {name,value} of [...planned.attributes]) if (current.getAttribute(name) !== value) current.setAttribute(name,value);
  children(current, [...planned.childNodes]);
  if (planned instanceof HTMLInputElement) {
    if (current.value !== formValue) current.value = formValue;
    current.checked = planned.checked;
  }
  if (planned instanceof HTMLSelectElement && current.value !== formValue) current.value = formValue;
}
function children(parent, planned) {
  const previous = [...parent.childNodes], used = new Set();
  let cursor = parent.firstChild;
  for (const next of planned) {
    const identity = key(next);
    let current = previous.find(n => !used.has(n) && compatible(n,next) && (identity !== null || key(n) === null));
    if (current) { used.add(current); update(current,next); }
    else current = next;
    if (current !== cursor) parent.insertBefore(current,cursor);
    cursor = current.nextSibling;
  }
  for (const old of previous) if (!used.has(old) && old.parentNode === parent) old.remove();
}
export function presentFrame(parent, planned) { children(parent, planned); }
