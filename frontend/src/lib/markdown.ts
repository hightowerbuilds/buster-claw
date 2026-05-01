import { marked } from "marked";

export function renderMarkdown(markdown: string) {
  return sanitizeHtml(marked(markdown) as string);
}

const blockedElements = new Set([
  "base",
  "button",
  "embed",
  "form",
  "frame",
  "frameset",
  "iframe",
  "input",
  "link",
  "meta",
  "object",
  "script",
  "style",
  "textarea",
]);

const uriAttributes = new Set(["href", "src", "xlink:href"]);
const allowedUriPattern = /^(https?:|mailto:|tel:|#|\/(?!\/))/i;

function sanitizeHtml(html: string) {
  if (typeof document === "undefined") return "";

  const template = document.createElement("template");
  template.innerHTML = html;

  for (const element of Array.from(template.content.querySelectorAll("*"))) {
    const tagName = element.tagName.toLowerCase();
    if (blockedElements.has(tagName)) {
      element.remove();
      continue;
    }

    for (const attr of Array.from(element.attributes)) {
      const name = attr.name.toLowerCase();
      const value = attr.value.trim();

      if (name.startsWith("on") || name === "style" || name === "srcdoc") {
        element.removeAttribute(attr.name);
        continue;
      }

      if (uriAttributes.has(name) && value && !allowedUriPattern.test(value)) {
        element.removeAttribute(attr.name);
      }
    }
  }

  return template.innerHTML;
}
