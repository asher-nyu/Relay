'use strict';
for (const element of document.querySelectorAll('[data-year]')) {
  element.textContent = String(new Date().getFullYear());
}
