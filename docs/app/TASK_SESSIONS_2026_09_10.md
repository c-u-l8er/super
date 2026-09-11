# Task session navigation — 10 September 2026

Tasks now display a provider-session panel, attributed to a task only when the last sent request carried a matching plan ID, revision, world and assigned bot. Other status is labeled bot-level. Open conversation selects the assigned bot’s current Conversation tab; it does not select a historical task conversation. Session observation is not persisted as runtime execution history.

Editor and explicitly attached plan-file context offer return links to the plan. Bot/provider switching and conversation restoration clear task reply attribution. Reload does not restore a live reply. Existing Send, review, Save and acceptance boundaries remain.

Validation: release build; 34 focused JavaScript tests; 19 new native disposable-world assertions with delayed local provider; 6 intent checks covering 24 mutations; 35 WebView ACL checks. Five screenshots were visually inspected, including narrow layout. Full report and screenshot manifest are in the September 10 Codex task outputs. No real-provider cycle was performed in this pass.

Remaining: durable task/conversation linkage, exact historical conversation navigation, expanded editor context and attention counts, combined multi-file acceptance and integration.
