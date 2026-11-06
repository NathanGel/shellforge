// One cleaning step shared by validate.js and render.js, so what is checked
// is what is rendered.
const BIDI = /[\u200e\u200f\u202a-\u202e\u2066-\u2069]/gu;
const ZERO_WIDTH = /[\u200b-\u200d\u2060\ufeff]/gu;
const CONTROL_EXCEPT_NL_TAB = /[^\P{Cc}\n\t]/gu;

// Line endings normalised (a lone CR is a newline), control and bidi
// characters removed. Newlines and tabs stay.
export function cleanText(text) {
  return text.replace(/\r\n?/g, "\n").replace(CONTROL_EXCEPT_NL_TAB, "").replace(BIDI, "");
}

// cleanText plus zero-width characters: the text as a reader sees it.
export function visibleText(text) {
  return cleanText(text).replace(ZERO_WIDTH, "");
}

export function isBlank(text) {
  return text === undefined || visibleText(text).trim() === "";
}
