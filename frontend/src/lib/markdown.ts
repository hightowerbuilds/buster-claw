import { marked } from "marked";

export function renderMarkdown(markdown: string) {
  return marked(markdown) as string;
}
