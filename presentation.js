/* Presentation-only cleanup for existing journey records. Stored flags and
   transaction safeguards remain intact, including records created before launch. */
(function () {
  function cleanLabel(value) {
    return value
      .replace(/\bSIMULATED(?:\s+[A-Z]+){0,3}\s*[:·—-]\s*/g, '')
      .replace(/\s*\((?:sample|simulated|demo)\)/gi, '')
      .replace(/\b(?:simulated|fictional)\s+/gi, '')
      .replace(/\s*[·—-]?\s*\b(?:simulated|fictional)\b\s*$/gi, '')
      .replace(/\bsample (?=project|journey|record|service plan|inspection|team|data|workspace|celebration)/gi, '')
      .replace(/\bsample (?=venue team|florist|caterer|photographer|designer|transport|beauty team|stationer|supplier|entertainment|accommodation|fee record)/gi, '')
      .replace(/\bsample (?=fitting studio|deliverable|handoff|planner|father|bridesmaid|sponsor|merchant|guest|logistics lead|consultant|videographer|decorator|stylist)/gi, '')
      .replace(/\b(?:saved|stored) (?:in|on) this (?:browser|device)\b/gi, 'Saved')
      .replace(/Offline · saved on this device/g, 'Offline')
      .replace(/\bLocal discussion\b/g, 'Discussion');
  }
  if (typeof module === 'object' && module.exports) { module.exports = cleanLabel; return; }
  function polish(root) {
    if (root.nodeType === 3) {
      if (root.parentElement?.closest('script,style,textarea,input,[contenteditable],#info-copy')) return;
      const next = cleanLabel(root.nodeValue);
      if (next !== root.nodeValue) root.nodeValue = next;
      return;
    }
    if (root.nodeType !== 1) return;
    root.querySelectorAll('p').forEach(p => {
      // Remove redundant storage implementation notes from the working surface.
      if (/^(?:Private in this browser|Notes stay in this browser|This creates a separate local workspace)/i.test(p.textContent.trim()) &&
          !p.closest('#info-dialog') && !p.querySelector('button,input,select,a')) p.remove();
    });
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach(polish);
  }
  polish(document.body);
  new MutationObserver(changes => changes.forEach(change => {
    if (change.type === 'characterData') polish(change.target);
    else change.addedNodes.forEach(polish);
  })).observe(document.body, {subtree:true, childList:true, characterData:true});
})();
