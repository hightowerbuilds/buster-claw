type DocsViewProps = {
  visible: boolean;
};

export function DocsView(props: DocsViewProps) {
  return (
    <div class="view-panel" classList={{ hidden: !props.visible }}>
      <div class="view-panel-content">
        <div class="view-header">
          <h2>Commands</h2>
        </div>

        <div class="docs-content">
          <p class="docs-intro">Type these in the chat input.</p>

          <div class="docs-command">
            <code>/search &lt;query&gt;</code>
            <span>Search the web and get an AI summary</span>
          </div>
          <div class="docs-command">
            <code>/ingest &lt;url&gt;</code>
            <span>Fetch a URL into the library</span>
          </div>
          <div class="docs-command">
            <code>/status</code>
            <span>Show pipeline status</span>
          </div>
          <div class="docs-command">
            <code>/remember &lt;text&gt;</code>
            <span>Save a fact to persistent memory</span>
          </div>
          <div class="docs-command">
            <code>/forget &lt;number&gt;</code>
            <span>Remove a memory by number</span>
          </div>
          <div class="docs-command">
            <code>/memories</code>
            <span>List all saved memories</span>
          </div>
          <div class="docs-command">
            <code>/mcp</code>
            <span>List connected MCP servers and tools</span>
          </div>
          <div class="docs-command">
            <code>/clear</code>
            <span>Clear chat history</span>
          </div>
          <div class="docs-command">
            <code>/help</code>
            <span>List all commands</span>
          </div>

          <p class="docs-note">You can also ask to search in plain language, e.g. "search for golang tutorials"</p>
        </div>
      </div>
    </div>
  );
}
