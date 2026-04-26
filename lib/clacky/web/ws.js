// ── WS — WebSocket connection manager ─────────────────────────────────────
//
// Responsibilities:
//   - Connect / reconnect with exponential backoff
//   - Queue outbound messages while disconnected, flush on reconnect
//   - Track active session subscription; restore it after reconnect
//   - Dispatch inbound server events to registered handlers
//
// Usage:
//   WS.onEvent(handler)        // register an event handler
//   WS.send({ type: "..." })   // send (queued if not yet connected)
//   WS.connect()               // start connection
// ─────────────────────────────────────────────────────────────────────────

const WS = (() => {
  // ── Private state ──────────────────────────────────────────────────────
  let _socket       = null;
  let _ready        = false;
  let _retryDelay   = 1000;        // ms; doubles on each failure, cap 30s
  let _retryTimer   = null;
  let _queue        = [];          // messages queued while disconnected
  let _handlers     = [];          // event handler callbacks
  let _subscribedId = null;        // currently subscribed session id

  const MAX_DELAY = 30_000;

  // ── Private helpers ────────────────────────────────────────────────────
  function _dispatch(event) {
    _handlers.forEach(fn => {
      try { fn(event); } catch (e) { console.error("[WS] handler error", e); }
    });
  }

  function _flushQueue() {
    const pending = _queue.splice(0);
    pending.forEach(msg => {
      try { _socket.send(JSON.stringify(msg)); }
      catch (e) { _queue.unshift(msg); } // re-queue on send error
    });
  }

  function _onOpen() {
    _ready      = true;
    _retryDelay = 1000;           // reset backoff on successful connect

    // Always request fresh session list on (re)connect
    _socket.send(JSON.stringify({ type: "list_sessions" }));

    // Restore subscription if we had one before disconnect
    if (_subscribedId) {
      _socket.send(JSON.stringify({ type: "subscribe", session_id: _subscribedId }));
    }

    _flushQueue();
    _dispatch({ type: "_ws_connected" });
  }

  function _onMessage(e) {
    let event;
    try { event = JSON.parse(e.data); }
    catch (ex) { console.error("[WS] parse error", ex); return; }
    _dispatch(event);
  }

  function _onClose(e) {
    // 1006 = abnormal closure (server rejected handshake, likely 401)
    if (e.code === 1006 && !Auth.passed) {
      Auth.reset();
      Auth.check();
      return;
    }
    _ready  = false;
    _socket = null;
    console.warn(`[WS] closed — retry in ${_retryDelay}ms`);
    _dispatch({ type: "_ws_disconnected" });

    _retryTimer = setTimeout(() => {
      _retryDelay = Math.min(_retryDelay * 2, MAX_DELAY);
      _connect();
    }, _retryDelay);
  }

  function _onError(err) {
    console.error("[WS] error", err);
    // onclose will fire automatically after onerror
  }

  function _connect() {
    if (_retryTimer) { clearTimeout(_retryTimer); _retryTimer = null; }
    if (_socket && (_socket.readyState === WebSocket.OPEN ||
                    _socket.readyState === WebSocket.CONNECTING)) return;

    const accessKey = Auth.getKey();
    const protocol = location.protocol === "https:" ? "wss:" : "ws:";
    const url = accessKey
      ? `${protocol}//${location.host}/ws?access_key=${encodeURIComponent(accessKey)}`
      : `${protocol}//${location.host}/ws`;
    _socket = new WebSocket(url);
    _socket.onopen    = _onOpen;
    _socket.onmessage = _onMessage;
    _socket.onclose   = _onClose;
    _socket.onerror   = _onError;
  }

  // ── Public API ─────────────────────────────────────────────────────────
  return {
    /** Register a handler for all server events. */
    onEvent(fn) { _handlers.push(fn); },

    /** Send a message. If not connected, queue it for later. */
    send(obj) {
      if (_ready && _socket) {
        try { _socket.send(JSON.stringify(obj)); return; }
        catch (e) { /* fall through to queue */ }
      }
      _queue.push(obj);
    },

    /** Track which session is currently subscribed (used for reconnect). */
    setSubscribedSession(id) { _subscribedId = id; },

    /** Start the connection. Call once on boot. */
    connect: _connect,

    /** True when the socket is open and ready. */
    get ready() { return _ready; },
  };
})();
