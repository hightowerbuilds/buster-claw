import { renderMarkdown } from "../lib/markdown";

type MarkdownArticleProps = {
  class?: string;
  markdown: string;
};

export function MarkdownArticle(props: MarkdownArticleProps) {
  return <article class={props.class || "report-article"} innerHTML={renderMarkdown(props.markdown)} />;
}
