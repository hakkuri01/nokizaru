# frozen_string_literal: true

module Nokizaru
  module Exporters
    # HTML template payload used by Html exporter
    module HtmlTemplate
      TEMPLATE = <<~'HTML'
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>Nokizaru Report - <%= h(meta['target'] || 'target') %></title>
          <style>
            body { font-family: system-ui, -apple-system, Segoe UI, Roboto, Helvetica, Arial, sans-serif; margin: 24px; }
            h1 { margin: 0 0 8px 0; }
            .muted { color: #666; }
            .card { border: 1px solid #ddd; border-radius: 10px; padding: 14px; margin: 14px 0; }
            .badge { display: inline-block; padding: 2px 8px; border-radius: 999px; font-size: 12px; border: 1px solid #ddd; }
            .sev-high { border-color: #c00; color: #c00; }
            .sev-medium { border-color: #b36b00; color: #b36b00; }
            .sev-low { border-color: #2a6; color: #2a6; }
            details { margin: 10px 0; }
            summary { cursor: pointer; font-weight: 600; }
            pre { white-space: pre-wrap; word-wrap: break-word; background: #f7f7f7; padding: 10px; border-radius: 8px; }
            table { border-collapse: collapse; width: 100%; }
            th, td { border-bottom: 1px solid #eee; padding: 8px; text-align: left; vertical-align: top; }
            input[type="search"] { width: 100%; padding: 10px; border-radius: 10px; border: 1px solid #ddd; }
          </style>
        </head>
        <body>
          <h1>Nokizaru Report</h1>
          <div class="muted">
            Target: <strong><%= h(meta['target'] || '') %></strong><br/>
            Started: <%= h(meta['started_at'] || '') %> &nbsp; | &nbsp; Completed: <%= h(meta['ended_at'] || '') %>
          </div>

          <% if findings.any? %>
            <div class="card">
              <h2 style="margin-top:0">Findings</h2>
              <input id="f" type="search" placeholder="Filter findings..." oninput="filterFindings()" />
              <table id="ft">
                <thead>
                  <tr><th>Severity</th><th>Title</th><th>Evidence</th><th>Recommendation</th></tr>
                </thead>
                <tbody>
                  <% findings.each do |f| %>
                    <% sev = (f['severity'] || 'low').downcase %>
                    <tr>
                      <td><span class="badge sev-<%= h(sev) %>"><%= h(sev.upcase) %></span></td>
                      <td><%= h(f['title'] || '') %></td>
                      <td><%= h(f['evidence'] || '') %></td>
                      <td><%= h(f['recommendation'] || '') %></td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <% if diff && diff.any? %>
            <div class="card">
              <h2 style="margin-top:0">Diff</h2>
              <% diff.each do |k, v| %>
                <details>
                  <summary><%= h(k) %> (+<%= (v['added']||[]).length %> / -<%= (v['removed']||[]).length %>)</summary>
                  <pre>ADDED
        <%= h(Array(v['added']).join("\n")) %>

        REMOVED
        <%= h(Array(v['removed']).join("\n")) %></pre>
                </details>
              <% end %>
            </div>
          <% end %>

          <div class="card">
            <h2 style="margin-top:0">Modules</h2>
            <% modules.each do |name, payload| %>
              <details>
                <summary><%= h(name) %></summary>
                <pre><%= h(pretty(payload)) %></pre>
              </details>
            <% end %>
          </div>

          <script>
            function filterFindings() {
              var q = document.getElementById('f').value.toLowerCase();
              var rows = document.querySelectorAll('#ft tbody tr');
              rows.forEach(function(r){
                var t = r.innerText.toLowerCase();
                r.style.display = t.indexOf(q) === -1 ? 'none' : '';
              });
            }
          </script>
        </body>
        </html>
      HTML
    end
  end
end
