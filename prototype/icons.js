/*
  shared line-icon set, used by app.js (index.html) and design-system.html.
  single source of truth so both pages render the identical icon shapes.
*/
var ICONS = {
  pin: '<path d="M12 21s-7-6.1-7-11.5A7 7 0 0 1 19 9.5C19 14.9 12 21 12 21Z"/><circle cx="12" cy="9.5" r="2.4"/>',
  search: '<circle cx="11" cy="11" r="6.5"/><path d="m20 20-3.6-3.6"/>',
  plus: '<path d="M12 5v14"/><path d="M5 12h14"/>',
  bell: '<path d="M6 9a6 6 0 0 1 12 0c0 4 1.5 5.5 1.5 5.5H4.5S6 13 6 9Z"/><path d="M9.5 17.5a2.5 2.5 0 0 0 5 0"/>',
  user: '<circle cx="12" cy="8" r="3.6"/><path d="M4.5 20c1.4-3.6 4.4-5.4 7.5-5.4S18.1 16.4 19.5 20"/>',
  heart: '<path d="M12 20s-7.2-4.5-9.7-9.1C.7 7.6 2.2 4.3 5.6 3.6c2-.4 3.9.5 5 2.1a1 1 0 0 0 1.6 0c1.1-1.6 3-2.5 5-2.1 3.4.7 4.9 4 3.3 7.3C19.2 15.5 12 20 12 20Z"/>',
  chevronLeft: '<path d="m14.5 5-7 7 7 7"/>',
  chevronRight: '<path d="m9.5 5 7 7-7 7"/>',
  close: '<path d="m5 5 14 14"/><path d="m19 5-14 14"/>',
  camera: '<path d="M4 8.5A1.5 1.5 0 0 1 5.5 7h2l1-2h7l1 2h2A1.5 1.5 0 0 1 20 8.5v9A1.5 1.5 0 0 1 18.5 19h-13A1.5 1.5 0 0 1 4 17.5Z"/><circle cx="12" cy="12.5" r="3.4"/>',
  alertTriangle: '<path d="M12 4.5 21 19H3Z"/><path d="M12 10v4"/><circle cx="12" cy="16.6" r=".35" fill="currentColor" stroke="none"/>',
  droplet: '<path d="M12 3.5s6 6.7 6 11a6 6 0 0 1-12 0c0-4.3 6-11 6-11Z"/>',
  bowl: '<path d="M3.5 12h17c0 3.9-3.8 7-8.5 7s-8.5-3.1-8.5-7Z"/><path d="M8 12V8.5a4 4 0 0 1 8 0V12"/>',
  check: '<path d="m5 13 4.5 4.5L19 8"/>',
  clock: '<circle cx="12" cy="12" r="8"/><path d="M12 8v4.3l3 1.9"/>',
  compass: '<circle cx="12" cy="12" r="8.2"/><path d="m14.8 9.2-1.8 5-5 1.8 1.8-5Z"/>',
  map: '<path d="M9 4 4 6v14l5-2 6 2 5-2V4l-5 2-6-2Z"/><path d="M9 4v14"/><path d="M15 6v14"/>',
  edit: '<path d="M4 20h4L18.5 9.5a2 2 0 0 0-2.8-2.8L5 17.4Z"/><path d="m14 7 3 3"/>',
  logout: '<path d="M9 5H5.5A1.5 1.5 0 0 0 4 6.5v11A1.5 1.5 0 0 0 5.5 19H9"/><path d="M14 15.5 18.5 11 14 6.5"/><path d="M18 11H9"/>',
  phone: '<path d="M6 4.5c0-.6.5-1 1-1h2.2c.4 0 .8.3.9.7l1 3a1 1 0 0 1-.3 1L9 9.5c.9 2 2.5 3.6 4.5 4.5l1.3-1.8a1 1 0 0 1 1-.3l3 1c.4.1.7.5.7.9V16c0 .6-.4 1-1 1h-.5C11.6 17 6 11.4 6 5.5Z"/>',
  location: '<path d="M12 3v3"/><path d="M12 18v3"/><path d="M3 12h3"/><path d="M18 12h3"/><circle cx="12" cy="12" r="4.5"/>',
  eye: '<path d="M2.5 12S6 5.8 12 5.8 21.5 12 21.5 12 18 18.2 12 18.2 2.5 12 2.5 12Z"/><circle cx="12" cy="12" r="3"/>',
  paw: '<path d="M12 12.5c-3.3 0-5.5 2.2-5.5 4.4 0 1.1.8 1.9 1.9 1.9 1.4 0 2-.8 3.6-.8s2.2.8 3.6.8c1.1 0 1.9-.8 1.9-1.9 0-2.2-2.2-4.4-5.5-4.4Z"/><circle cx="7.6" cy="10.2" r="1.7"/><circle cx="12" cy="8.2" r="1.8"/><circle cx="16.4" cy="10.2" r="1.7"/><circle cx="4.6" cy="14" r="1.5"/><circle cx="19.4" cy="14" r="1.5"/>',
  award: '<circle cx="12" cy="9.5" r="5.5"/><path d="m8.8 14 -1.6 6 4.8-2.6L16.8 20l-1.6-6"/>',
  sliders: '<path d="M4 7h9"/><circle cx="16.5" cy="7" r="2.2"/><path d="M20 7h.5"/><path d="M4 16.5h3"/><circle cx="10.5" cy="16.5" r="2.2"/><path d="M14 16.5h6.5"/>',
  trash: '<path d="M5 7h14"/><path d="M9.5 7V5.2c0-.6.5-1.2 1.2-1.2h2.6c.7 0 1.2.6 1.2 1.2V7"/><path d="M6.5 7 7.3 19a1.5 1.5 0 0 0 1.5 1.4h6.4a1.5 1.5 0 0 0 1.5-1.4L17.5 7"/>',
  info: '<circle cx="12" cy="12" r="8.2"/><path d="M12 11v5"/><circle cx="12" cy="8" r=".4" fill="currentColor" stroke="none"/>'
};

function icon(name, opts){
  opts = opts || {};
  var size = opts.size || 22;
  var cls = opts.class ? ' class="' + opts.class + '"' : '';
  var fill = opts.filled ? 'currentColor' : 'none';
  var body = ICONS[name] || '';
  return '<svg' + cls + ' width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="' + fill + '" ' +
    'stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + body + '</svg>';
}
