// Shared, immutable capture bounds: old 0104 static prefixes and observed
// 0102 readback. Neither covers the rejected final bytes or authorizes writes.
export const extendedCaptureRegions=Object.freeze([['deviceInfo',3,34,56],['parameters',5,63,56],['keymap',8,511,56],['colors',10,511,56],['macroData',20,3071,54]].map(row=>Object.freeze(row)));
