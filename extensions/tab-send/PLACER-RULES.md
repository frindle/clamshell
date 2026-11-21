# What the placer must do for tab-send (the placer side is not built yet)

1. **Origin rule.** Browsers set an `Origin` header on a WebSocket opened from an extension (a `chrome-extension://` or `moz-extension://` origin). The placer must reject any socket or HTTP request whose `Origin` is missing or is an `http`/`https` web origin, so a web page in any browser cannot talk to it. Bind to 127.0.0.1 only.
2. **Silent until proven.** The first socket message is `hello {cnonce, proof}` with `proof = HMAC-SHA256(token, "hello|" + cnonce)`. Verify it in constant time. Send nothing keyed (no `challenge`) to a peer whose proof fails; close the socket.
3. **Then prove yourself.** `challenge {snonce, proof = HMAC(token, "server|cnonce|snonce")}`, expect `auth {proof = HMAC(token, "client|cnonce|snonce")}`, then `ready`. Nonces are random, at least 16 bytes, hex.
4. **Token.** At least 32 random characters (the options page can generate one). The extension refuses shorter tokens.
5. **HTTP.** Every request carries `X-Desk-Session` (the server nonce), a rising `X-Desk-Seq` and `X-Desk-Sig = HMAC(token, "http|snonce|seq|body")`. Reject a repeated or lower sequence number.
6. **Rates.** Do not send more than ten `open-tab` messages a minute; the extension drops the rest. Tabs for local or private addresses wait for a click on the toolbar button.
